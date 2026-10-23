//! Offline audio analysis on utility workers. Jobs survive interruption.

use std::sync::Arc;
use std::time::{Duration, Instant};

use meret_analysis::Analyzer;
use meret_engine::decode;
use meret_model::RecordingId;
use meret_store::{ANALYSIS_VERSION, AnalysisRow, JobCounts, NewJob, QueuedJob};

use crate::Core;

const QUEUE: &str = "analysis";
const VERB: &str = "analysing";
const TICK: Duration = Duration::from_millis(250);

pub(crate) struct State {
    dirty: bool,
    last_bump: Instant,
    generation: u64,
}

impl Default for State {
    fn default() -> Self {
        Self { dirty: false, last_bump: Instant::now(), generation: 0 }
    }
}

pub(crate) fn spawn_runner(core: Arc<Core>) {
    if let Err(error) = core.store.requeue_running(QUEUE) {
        tracing::error!(%error, "could not recover analysis jobs");
    }
    let workers = worker_count();
    for worker in 0..workers {
        let core = core.clone();
        std::thread::Builder::new()
            .name(format!("meret-analysis-{worker}"))
            .spawn(move || run(&core, worker))
            .expect("analysis thread");
    }
}

fn worker_count() -> usize {
    (std::thread::available_parallelism().map_or(1, usize::from) / 2).max(1)
}

pub(crate) fn seed(core: &Core) -> crate::Result<usize> {
    let recordings = core.store.analysis_candidates()?;
    let jobs = core.store.writer.write(move |tx| {
        let mut jobs = Vec::with_capacity(recordings.len());
        let mut reset = tx.prepare_cached(
            "UPDATE job SET state = 'queued' WHERE dedupe_key = ?1 AND kind = 'analysis' AND state = 'done'
             AND NOT EXISTS (SELECT 1 FROM analysis WHERE recording_id = ?2 AND version = ?3)")?;
        for recording in recordings {
            let key = format!("analyse:recording:{}", recording.0);
            reset.execute((&key, recording.0, ANALYSIS_VERSION))?;
            jobs.push(NewJob { key, kind: QUEUE.into(), payload: None, priority: 0 });
        }
        Ok(jobs)
    })?;
    let inserted = core.store.enqueue_jobs(jobs)?;
    wake(core);
    publish(core);
    Ok(inserted)
}

fn run(core: &Core, worker: usize) {
    utility_qos();
    loop {
        let generation = core.analysis_state.lock().generation;
        if worker == 0 {
            publish(core);
        }
        let playing = core.now.borrow().anchor.is_some_and(|a| a.rate > 0.0);
        let throttled = worker != 0 && playing;
        let mut failed = false;
        if !throttled {
            match core.store.next_job(QUEUE, now_ms()) {
                Ok(Some(job)) => {
                    one(core, job);
                    wake(core);
                    publish(core);
                    continue;
                }
                Ok(None) => {}
                Err(error) => {
                    tracing::error!(%error, "could not take an analysis job");
                    failed = true;
                }
            }
        }
        let mut state = core.analysis_state.lock();
        if state.generation != generation {
            continue;
        }
        if throttled || failed {
            core.analysis_wake.wait_for(&mut state, TICK);
        } else if worker == 0 && state.dirty {
            let wait = Duration::from_secs(1).saturating_sub(state.last_bump.elapsed());
            core.analysis_wake.wait_for(&mut state, wait);
        } else {
            core.analysis_wake.wait(&mut state);
        }
    }
}

fn wake(core: &Core) {
    core.analysis_state.lock().generation += 1;
    core.analysis_wake.notify_all();
}

fn one(core: &Core, job: QueuedJob) {
    let recording = job.key.strip_prefix("analyse:recording:").and_then(|id| id.parse().ok()).map(RecordingId);
    let result = recording.ok_or_else(|| "invalid recording analysis job".to_string())
        .and_then(|recording| analyse(core, recording));
    let result = match result {
        Ok(()) => core.store.finish_job(job.id, now_ms()),
        Err(error) => core.store.fail_job(job.id, &error, None, now_ms()),
    };
    if let Err(error) = result {
        tracing::error!(%error, "could not record analysis outcome");
    }
}

fn analyse(core: &Core, recording: RecordingId) -> Result<(), String> {
    let path = core.store.analysis_file(recording).map_err(|e| e.to_string())?
        .ok_or_else(|| "recording has no present file on an online root".to_string())?;
    let mut decoder = decode::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let spec = decoder.spec();
    let mut analyzer = Analyzer::new(spec.channels as usize, spec.sample_rate);
    let mut pcm = Vec::new();
    let mut samples = Vec::new();
    loop {
        pcm.clear();
        let frames = decoder.read(&mut pcm).map_err(|e| format!("{}: {e}", path.display()))?;
        if frames == 0 {
            break;
        }
        samples.clear();
        samples.extend(pcm.iter().map(|&sample| sample as f32 / 2_147_483_648.0));
        analyzer.push(&samples);
    }
    let analysis = analyzer.finish();
    // Patches are idempotent, so a reload between the write and the patch loses nothing;
    // readers never wait on the database writer.
    let analysis_write = core.analysis_write.lock();
    let patches = core.store.save_analysis(AnalysisRow {
        recording_id: recording,
        loudness_lufs: analysis.loudness_lufs,
        peak_db: analysis.peak_db,
        dr: analysis.dr,
        body: analysis.body.pack(),
        analysed_at: now_ms(),
        version: ANALYSIS_VERSION,
    }).map_err(|e| e.to_string())?;
    core.columns.write().patch_analysis(&patches);
    drop(analysis_write);
    core.analysis_state.lock().dirty = true;
    let loaded = core.now.borrow().track.filter(|&track| core.store.track_analysis(track).ok().flatten()
        .is_some_and(|row| row.recording_id == recording));
    core.now.send_modify(|now| {
        if loaded.is_some() && now.track == loaded {
            now.body = Some(analysis.body);
            now.loudness_lufs = analysis.loudness_lufs;
            now.dr = now.track.and_then(|track| patches.iter().find(|p| p.track == track)).and_then(|p| p.dr);
        }
    });
    Ok(())
}

fn publish(core: &Core) {
    // Serialize publication so a worker cannot replace newer counts with older ones.
    let mut state = core.analysis_state.lock();
    let counts = match counts(core) {
        Ok(counts) => counts,
        Err(error) => return tracing::error!(%error, "could not count analysis jobs"),
    };
    let bump = state.dirty && state.last_bump.elapsed() >= Duration::from_secs(1);
    if bump {
        state.dirty = false;
        state.last_bump = Instant::now();
    }
    core.status.send_if_modified(|status| {
        let before = status.jobs.iter().find(|job| job.verb == VERB).cloned();
        let pending = counts.queued + counts.running;
        let group = (pending > 0).then(|| meret_jobs::JobGroupStatus {
            verb: VERB.into(),
            done: counts.done + counts.failed,
            total: counts.done + counts.failed + pending,
            paused_because: None,
        });
        let changed = group != before;
        if changed {
            status.jobs.retain(|job| job.verb != VERB);
            status.jobs.extend(group);
        }
        if bump {
            status.library_version += 1;
        }
        changed || bump
    });
}


pub(crate) fn counts(core: &Core) -> crate::Result<JobCounts> {
    Ok(core.store.job_counts(QUEUE)?)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as i64
}

#[cfg(target_os = "macos")]
fn utility_qos() {
    // Applies only to this offline worker, never the audio callback.
    unsafe { libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0); }
}

#[cfg(not(target_os = "macos"))]
fn utility_qos() {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};

    #[test]
    fn fixture_job_persists_analysis_and_patches_columns() {
        let dir = std::env::temp_dir().join(format!("meret-analysis-job-{}-{}", std::process::id(), now_ms()));
        std::fs::create_dir_all(dir.join("music")).unwrap();
        std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"),
            dir.join("music/tone.flac")).unwrap();
        let (scans, _) = crossbeam_channel::unbounded();
        let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: String::new() }, scans).unwrap();
        let root = meret_library::add_root(&core.store, &dir.join("music")).unwrap();
        meret_library::scan(&core.store, root, &|_| {}).unwrap();
        *core.columns.write() = core.store.load_columns().unwrap();
        assert_eq!(seed(&core).unwrap(), 1);
        let job = core.store.next_job(QUEUE, now_ms()).unwrap().unwrap();
        one(&core, job);
        let track = core.columns.read().track[0];
        let saved = core.store.track_analysis(track).unwrap().unwrap();
        assert_eq!(saved.version, ANALYSIS_VERSION);
        assert!(saved.loudness_lufs.is_some());
        assert!(saved.peak_db.is_some());
        assert!(meret_analysis::BodySummary::unpack(&saved.body).is_some());
        let columns = core.columns.read();
        assert_eq!(columns.dr[0], saved.dr.unwrap());
        assert_eq!(columns.loudness[0], (saved.loudness_lufs.unwrap() * 10.0).round() as i16);
        drop(columns);
        assert_eq!(counts(&core).unwrap().done, 1);
        assert_eq!(seed(&core).unwrap(), 0);
        core.store.writer.write(move |tx| {
            tx.execute("UPDATE analysis SET version = 0", [])?;
            Ok(())
        }).unwrap();
        seed(&core).unwrap();
        assert_eq!(counts(&core).unwrap().queued, 1);
        std::fs::write(dir.join("music/tone.flac"), b"broken stream").unwrap();
        let job = core.store.next_job(QUEUE, now_ms()).unwrap().unwrap();
        one(&core, job);
        assert_eq!(counts(&core).unwrap().failed, 1);
        seed(&core).unwrap();
        assert_eq!(counts(&core).unwrap().queued, 0);
        assert!(core.store.read(|c| c.query_row("SELECT last_error FROM job WHERE kind = 'analysis'",
            [], |row| row.get::<_, String>(0))).unwrap().contains("tone.flac"));
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
