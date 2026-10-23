//! The last queue and release-level pick-up points, written off the audio thread.

use meret_model::{EntityKind, Idiom, ListenUid, RecordingId, ReleaseId};
use rusqlite::{OptionalExtension, params};

use crate::{Artwork, Result, Store};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedQueue {
    pub items_json: String,
    pub cursor: usize,
    pub position_ms: u64,
    pub playing: bool,
    pub updated_at: i64,
    pub device: String,
    /// The listen open when this was saved; a resume continues it.
    pub listen: Option<ListenUid>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ResumeRow {
    pub release: ReleaseId,
    pub title: String,
    pub credit: Option<String>,
    pub cover: Option<Artwork>,
    pub recording: RecordingId,
    pub recording_title: String,
    pub disc: u32,
    pub number: u32,
    pub position_ms: u64,
    pub length_ms: Option<u64>,
    pub idiom: Option<Idiom>,
    pub updated_at: i64,
}

impl Store {
    pub fn save_queue(&self, items: String, cursor: usize, position_ms: u64, playing: bool, device: &str,
        listen: Option<ListenUid>) -> Result<()> {
        let device = device.to_owned();
        self.writer.write(move |tx| {
            tx.execute(
                "INSERT INTO queue_state(id,items,cursor,position_ms,playing,updated_at,device,listen)
                 VALUES(1,?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(id) DO UPDATE SET
                 items=excluded.items,cursor=excluded.cursor,position_ms=excluded.position_ms,
                 playing=excluded.playing,updated_at=excluded.updated_at,device=excluded.device,listen=excluded.listen",
                params![items, cursor as i64, position_ms as i64, playing, now_ms(), device, listen.map(|l| l.to_string())],
            )?;
            Ok(())
        })
    }

    pub fn load_queue(&self) -> Result<Option<SavedQueue>> {
        self.read(|c| c.query_row(
            "SELECT items,cursor,position_ms,playing,updated_at,device,listen FROM queue_state WHERE id=1",
            [],
            |r| Ok(SavedQueue { items_json: r.get(0)?, cursor: r.get::<_, i64>(1)? as usize, position_ms: r.get::<_, i64>(2)? as u64,
                playing: r.get(3)?, updated_at: r.get(4)?, device: r.get(5)?,
                listen: r.get::<_, Option<String>>(6)?.and_then(|uid| uid.parse().ok()).map(ListenUid) }),
        ).optional())
    }

    pub fn upsert_resume(&self, release: ReleaseId, recording: RecordingId, position_ms: u64, device: &str) -> Result<()> {
        let device = device.to_owned();
        self.writer.write(move |tx| {
            tx.execute(
                "INSERT INTO resume(subject_kind,subject_id,recording_id,position_ms,updated_at,device)
                 VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT(subject_kind,subject_id) DO UPDATE SET
                 recording_id=excluded.recording_id,position_ms=excluded.position_ms,
                 updated_at=excluded.updated_at,device=excluded.device",
                params![EntityKind::Release as i64, release.0, recording.0, position_ms as i64, now_ms(), device],
            )?;
            Ok(())
        })
    }

    pub fn clear_resume(&self, release: ReleaseId) -> Result<()> {
        self.writer.write(move |tx| {
            tx.execute("DELETE FROM resume WHERE subject_kind=?1 AND subject_id=?2", params![EntityKind::Release as i64, release.0])?;
            Ok(())
        })
    }

    pub fn resume_for(&self, release: ReleaseId) -> Result<Option<(RecordingId, u64)>> {
        self.read(|c| c.query_row(
            "SELECT recording_id,position_ms FROM resume WHERE subject_kind=?1 AND subject_id=?2 AND recording_id IS NOT NULL",
            params![EntityKind::Release as i64, release.0],
            |r| Ok((RecordingId(r.get(0)?), r.get::<_, i64>(1)? as u64)),
        ).optional())
    }

    /// Pick-up points, newest first, only where something is partway: a
    /// point at the top of a release's first track is a fresh start, not a
    /// pick-up.
    pub fn resume_points(&self, limit: usize) -> Result<Vec<ResumeRow>> {
        let mut rows = self.read(|c| c.prepare(
            "SELECT rl.id,rl.title,COALESCE(rl.album_artist_credit,
                (SELECT a.name FROM credit cr JOIN agent a ON a.id=cr.agent_id
                 WHERE cr.subject_kind=3 AND cr.subject_id=rl.id AND cr.role='album_artist' ORDER BY cr.sort LIMIT 1)),
                r.id,COALESCE(t.title,r.title),COALESCE(m.position,0),COALESCE(t.position,0),
                p.position_ms,COALESCE(t.length_ms,r.length_ms),rl.idiom,p.updated_at
             FROM resume p JOIN release rl ON rl.id=p.subject_id JOIN recording r ON r.id=p.recording_id
             LEFT JOIN track t ON t.id=(SELECT t2.id FROM track t2 JOIN medium m2 ON m2.id=t2.medium_id
                 JOIN edition e2 ON e2.id=m2.edition_id WHERE e2.release_id=rl.id AND t2.recording_id=r.id
                 ORDER BY m2.position,t2.position,t2.id LIMIT 1)
             LEFT JOIN medium m ON m.id=t.medium_id
             WHERE p.subject_kind=?1 AND (p.position_ms>0 OR EXISTS(SELECT 1 FROM track t3 JOIN medium m3 ON m3.id=t3.medium_id
                 JOIN edition e3 ON e3.id=m3.edition_id WHERE e3.release_id=rl.id AND t3.id<>t.id
                 AND (COALESCE(m3.position,0)<COALESCE(m.position,0)
                     OR COALESCE(m3.position,0)=COALESCE(m.position,0) AND COALESCE(t3.position,0)<COALESCE(t.position,0))))
             ORDER BY p.updated_at DESC,rl.id DESC LIMIT ?2"
        )?.query_map(params![EntityKind::Release as i64, limit as i64], |r| {
            let idiom: Option<u8> = r.get(9)?;
            Ok(ResumeRow { release: ReleaseId(r.get(0)?), title: r.get(1)?, credit: r.get(2)?, cover: None,
                recording: RecordingId(r.get(3)?), recording_title: r.get(4)?, disc: r.get(5)?, number: r.get(6)?,
                position_ms: r.get::<_, i64>(7)? as u64, length_ms: r.get::<_, Option<i64>>(8)?.map(|ms| ms as u64),
                idiom: idiom.and_then(|v| Idiom::ALL.into_iter().find(|i| *i as u8 == v)), updated_at: r.get(10)? })
        })?.collect::<rusqlite::Result<Vec<_>>>())?;
        let ids: Vec<_> = rows.iter().map(|r| r.release).collect();
        let mut art = self.release_art(&ids)?;
        for row in &mut rows {
            row.cover = art.remove(&row.release);
        }
        Ok(rows)
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_and_release_resume_round_trip_across_reopen() {
        let dir = std::env::temp_dir().join(format!("meret-memory-{}-{}", std::process::id(), now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("library.db");
        let store = Store::open(&path).unwrap();
        assert!(store.load_queue().unwrap().is_none());
        store.writer.write(|tx| {
            tx.execute_batch("INSERT INTO release(id,title,idiom,rev) VALUES(1,'Release One',5,1),(2,'Release Two',5,1);
                INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
                INSERT INTO medium(id,edition_id,position) VALUES(1,1,1);
                INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'First Cue',90000,1),(2,'Second Cue',100000,1);
                INSERT INTO track(id,medium_id,position,recording_id,title,rev) VALUES(1,1,2,1,'First Cue',1);")?;
            Ok(())
        }).unwrap();
        let device = store.device_id().unwrap();
        let listen = ListenUid::new();
        store.save_queue("[]".into(), 0, 3000, true, &device, Some(listen)).unwrap();
        store.save_queue("[{\"token\":1}]".into(), 1, 3456, false, &device, Some(listen)).unwrap();
        store.upsert_resume(ReleaseId(1), RecordingId(1), 1000, &device).unwrap();
        store.upsert_resume(ReleaseId(1), RecordingId(1), 3456, &device).unwrap();
        store.upsert_resume(ReleaseId(2), RecordingId(2), 2000, &device).unwrap();
        store.writer.write(|tx| { tx.execute("UPDATE resume SET updated_at=10 WHERE subject_id=1", [])?; Ok(()) }).unwrap();
        drop(store);
        let store = Store::open(&path).unwrap();
        let saved = store.load_queue().unwrap().unwrap();
        assert_eq!((saved.items_json.as_str(), saved.cursor, saved.position_ms, saved.playing, saved.device.as_str(), saved.listen),
            ("[{\"token\":1}]", 1, 3456, false, device.as_str(), Some(listen)));
        store.save_queue("[]".into(), 0, 0, false, &device, None).unwrap();
        assert_eq!(store.load_queue().unwrap().unwrap().listen, None, "a stopped queue carries no listen");
        assert_eq!(store.resume_for(ReleaseId(1)).unwrap(), Some((RecordingId(1), 3456)));
        assert_eq!(store.resume_points(1).unwrap()[0].release, ReleaseId(2));
        let rows = store.resume_points(10).unwrap();
        assert_eq!(rows.len(), 2);
        let row = &rows[1];
        assert_eq!((row.title.as_str(), row.recording_title.as_str(), row.disc, row.number, row.position_ms, row.length_ms, row.idiom),
            ("Release One", "First Cue", 1, 2, 3456, Some(90000), Some(Idiom::Score)));
        store.clear_resume(ReleaseId(1)).unwrap();
        assert!(store.resume_for(ReleaseId(1)).unwrap().is_none());
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_point_at_the_top_of_the_first_track_is_not_offered() {
        let dir = std::env::temp_dir().join(format!("meret-memory-top-{}-{}", std::process::id(), now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| {
            tx.execute_batch("INSERT INTO release(id,title,idiom,rev) VALUES(1,'Two Discs',5,1),(2,'No Track',5,1);
                INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
                INSERT INTO medium(id,edition_id,position) VALUES(1,1,1),(2,1,2);
                INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'First',90000,1),(2,'Second',90000,1),(3,'Disc Two',90000,1),(4,'Loose',90000,1);
                INSERT INTO track(id,medium_id,position,recording_id,title,rev) VALUES(1,1,1,1,'First',1),(2,1,2,2,'Second',1),(3,2,1,3,'Disc Two',1);")?;
            Ok(())
        }).unwrap();
        let device = store.device_id().unwrap();
        let offered = |store: &Store| store.resume_points(10).unwrap().into_iter().map(|r| (r.release, r.recording, r.position_ms)).collect::<Vec<_>>();
        store.upsert_resume(ReleaseId(1), RecordingId(1), 0, &device).unwrap();
        store.upsert_resume(ReleaseId(2), RecordingId(4), 0, &device).unwrap();
        assert_eq!(offered(&store), [], "the top of the first track, and a trackless recording at zero, are fresh starts");
        store.upsert_resume(ReleaseId(1), RecordingId(1), 1, &device).unwrap();
        assert_eq!(offered(&store), [(ReleaseId(1), RecordingId(1), 1)]);
        store.upsert_resume(ReleaseId(1), RecordingId(2), 0, &device).unwrap();
        assert_eq!(offered(&store), [(ReleaseId(1), RecordingId(2), 0)], "the top of a later track is partway through the release");
        store.upsert_resume(ReleaseId(1), RecordingId(3), 0, &device).unwrap();
        assert_eq!(offered(&store), [(ReleaseId(1), RecordingId(3), 0)], "so is the top of a later disc");
        store.upsert_resume(ReleaseId(2), RecordingId(4), 5, &device).unwrap();
        assert_eq!(offered(&store).len(), 2);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
