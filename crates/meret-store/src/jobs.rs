use rusqlite::OptionalExtension;

use crate::{Result, Store};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NewJob {
    pub key: String,
    pub kind: String,
    pub payload: Option<String>,
    pub priority: i32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueuedJob {
    pub id: i64,
    pub key: String,
    pub payload: Option<String>,
    pub attempts: u32,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct JobCounts {
    pub queued: u64,
    pub running: u64,
    pub done: u64,
    pub failed: u64,
    pub next_run_after: Option<i64>,
}

impl Store {
    /// Queues new keys and raises the priority of existing queued jobs.
    pub fn enqueue_jobs(&self, jobs: Vec<NewJob>) -> Result<usize> {
        self.writer.write(move |tx| {
            let now = now_ms();
            let mut inserted = 0;
            let mut insert = tx.prepare_cached(
                "INSERT INTO job (dedupe_key, kind, payload, priority, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?5) ON CONFLICT(dedupe_key) DO NOTHING",
            )?;
            let mut raise = tx.prepare_cached(
                "UPDATE job SET priority = ?2, updated_at = ?3
                 WHERE dedupe_key = ?1 AND state = 'queued' AND priority < ?2",
            )?;
            for job in jobs {
                let new = insert.execute((&job.key, &job.kind, &job.payload, job.priority, now))?;
                inserted += new;
                if new == 0 {
                    raise.execute((&job.key, job.priority, now))?;
                }
            }
            Ok(inserted)
        })
    }

    /// Takes the highest-priority due job, oldest first.
    pub fn next_job(&self, kind: &str, now_ms: i64) -> Result<Option<QueuedJob>> {
        let kind = kind.to_owned();
        self.writer.write(move |tx| {
            tx.query_row(
                "UPDATE job SET state = 'running', updated_at = ?2 WHERE id = (
                     SELECT id FROM job WHERE kind = ?1 AND state = 'queued' AND run_after <= ?2
                     ORDER BY priority DESC, created_at, id LIMIT 1)
                 RETURNING id, dedupe_key, payload, attempts",
                (&kind, now_ms),
                |r| Ok(QueuedJob { id: r.get(0)?, key: r.get(1)?, payload: r.get(2)?, attempts: r.get(3)? }),
            ).optional()
        })
    }

    pub fn finish_job(&self, id: i64, now_ms: i64) -> Result<()> {
        self.writer.write(move |tx| {
            tx.execute("UPDATE job SET state = 'done', updated_at = ?2 WHERE id = ?1", (id, now_ms))?;
            Ok(())
        })
    }

    /// Retries later, or fails permanently; retains the error in either case.
    pub fn fail_job(&self, id: i64, error: &str, retry_at: Option<i64>, now_ms: i64) -> Result<()> {
        let error = error.to_owned();
        self.writer.write(move |tx| {
            tx.execute(
                "UPDATE job SET state = ?2, attempts = attempts + 1, run_after = COALESCE(?3, run_after),
                     last_error = ?4, updated_at = ?5 WHERE id = ?1",
                (id, if retry_at.is_some() { "queued" } else { "failed" }, retry_at, error, now_ms),
            )?;
            Ok(())
        })
    }

    /// Recovers requests interrupted by a crash or shutdown.
    pub fn requeue_running(&self) -> Result<usize> {
        self.writer.write(|tx| {
            tx.execute("UPDATE job SET state = 'queued', updated_at = ?1 WHERE state = 'running'", [now_ms()])
        })
    }

    pub fn job_counts(&self, kind: &str) -> Result<JobCounts> {
        self.read(|c| {
            let mut counts = JobCounts::default();
            let mut stmt = c.prepare_cached(
                "SELECT state, COUNT(*), MIN(run_after) FROM job WHERE kind = ?1 GROUP BY state",
            )?;
            for row in stmt.query_map([kind], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64, r.get::<_, Option<i64>>(2)?)))? {
                let (state, count, next) = row?;
                match state.as_str() {
                    "queued" => { counts.queued = count; counts.next_run_after = next; }
                    "running" => counts.running = count,
                    "done" => counts.done = count,
                    "failed" => counts.failed = count,
                    _ => {}
                }
            }
            Ok(counts)
        })
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jobs_dedupe_prioritize_retry_and_recover() {
        let dir = std::env::temp_dir().join(format!("meret-jobs-{}", ulid::Ulid::generate()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("library.db");
        let store = Store::open(&path).unwrap();
        let new = |key: &str, kind: &str, priority| NewJob {
            key: key.into(), kind: kind.into(), payload: Some(format!("payload:{key}")), priority,
        };
        assert_eq!(store.enqueue_jobs(vec![new("first", "musicbrainz", 1), new("second", "musicbrainz", 1),
            new("raised", "musicbrainz", 0), new("foreign", "other", 100)]).unwrap(), 4);
        assert_eq!(store.enqueue_jobs(vec![new("raised", "musicbrainz", 10), new("raised", "musicbrainz", 0)]).unwrap(), 0);
        let raised = store.next_job("musicbrainz", 100).unwrap().unwrap();
        assert_eq!((raised.key.as_str(), raised.attempts, raised.payload.as_deref()), ("raised", 0, Some("payload:raised")));
        store.fail_job(raised.id, "offline", Some(200), 100).unwrap();
        let first = store.next_job("musicbrainz", 100).unwrap().unwrap();
        assert_eq!(first.key, "first");
        store.finish_job(first.id, 101).unwrap();
        let second = store.next_job("musicbrainz", 100).unwrap().unwrap();
        assert_eq!(second.key, "second");
        assert!(store.next_job("musicbrainz", 199).unwrap().is_none());
        assert_eq!(store.job_counts("musicbrainz").unwrap(), JobCounts {
            queued: 1, running: 1, done: 1, failed: 0, next_run_after: Some(200),
        });
        drop(store);
        let store = Store::open(&path).unwrap();
        assert_eq!(store.requeue_running().unwrap(), 1);
        assert_eq!(store.requeue_running().unwrap(), 0);
        let retry = store.next_job("musicbrainz", 200).unwrap().unwrap();
        assert_eq!((retry.id, retry.attempts), (raised.id, 1));
        store.fail_job(retry.id, "not found", None, 200).unwrap();
        assert_eq!(store.enqueue_jobs(vec![new("raised", "musicbrainz", 100), new("first", "musicbrainz", 100)]).unwrap(), 0);
        let recovered = store.next_job("musicbrainz", 200).unwrap().unwrap();
        assert_eq!((recovered.id, recovered.attempts), (second.id, 0));
        store.finish_job(recovered.id, 201).unwrap();
        assert!(store.next_job("musicbrainz", 1000).unwrap().is_none());
        assert_eq!(store.job_counts("musicbrainz").unwrap(), JobCounts {
            queued: 0, running: 0, done: 2, failed: 1, next_run_after: None,
        });
        let error: (String, u32) = store.read(|c| c.query_row(
            "SELECT last_error, attempts FROM job WHERE id = ?1", [raised.id], |r| Ok((r.get(0)?, r.get(1)?)),
        )).unwrap();
        assert_eq!(error, ("not found".into(), 2));
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
