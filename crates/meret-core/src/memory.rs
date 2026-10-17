//! Queue checkpoints and release-level resume, never on the audio callback.

use std::time::{Duration, Instant};

use meret_engine::Anchor;
use meret_player::QueueItem;

use crate::{Core, Result};

const CHECKPOINT: Duration = Duration::from_secs(10);

pub(crate) struct Pending {
    pub items: Vec<QueueItem>,
    pub cursor: usize,
    pub position_ms: u64,
}

#[derive(Default)]
pub(crate) struct State {
    last_write: Option<Instant>,
    completed: Option<u64>,
    pub stopping: bool,
}

pub(crate) fn restore(core: &Core) -> Result<()> {
    let Some(saved) = core.store.load_queue()? else { return Ok(()) };
    let items: Vec<QueueItem> = serde_json::from_str(&saved.items_json)
        .map_err(|e| crate::CoreError::Query(format!("could not restore queue: {e}")))?;
    let Some(item) = items.get(saved.cursor) else { return Ok(()) };
    let mut now = crate::now::describe_item(core, item);
    now.item = Some(item.token);
    now.anchor = Some(Anchor { item: item.token, position_frames: saved.position_ms, sample_rate: 1000,
        at_ns: meret_engine::clock::now_ns(), rate: 0.0 });
    core.now.send_replace(now);
    *core.pending.lock() = Some(Pending { items, cursor: saved.cursor, position_ms: saved.position_ms });
    Ok(())
}

pub(crate) fn on_started(core: &Core, token: u64) {
    let mut state = core.memory_state.lock();
    state.completed = None;
    state.last_write = None;
    report(save(core, Some(token), Some(0), true, true));
}

pub(crate) fn on_anchor(core: &Core, anchor: &Anchor) {
    if core.now.borrow().item != Some(anchor.item) {
        return;
    }
    checkpoint(core, anchor.rate > 0.0, anchor.rate == 0.0);
}

pub(crate) fn on_tick(core: &Core) {
    if core.now.borrow().anchor.is_some_and(|a| a.rate > 0.0) {
        checkpoint(core, true, false);
    }
}

fn checkpoint(core: &Core, playing: bool, immediate: bool) {
    let mut state = core.memory_state.lock();
    if !immediate && state.last_write.is_some_and(|last| last.elapsed() < CHECKPOINT) {
        return;
    }
    let active = core.now.borrow().item;
    let resume = active.is_some() && state.completed != active;
    if let Err(error) = save(core, active, None, playing, resume) {
        report(Err(error));
    } else {
        state.last_write = Some(Instant::now());
    }
}

pub(crate) fn on_ended(core: &Core, token: u64) {
    let release = {
        let player = core.player.lock();
        let q = player.queue();
        let Some(at) = q.position_of(token) else { return };
        let Some(release) = q.items[at].release else { return };
        if q.items.get(at + 1).is_some_and(|next| next.release == Some(release)) {
            return;
        }
        release
    };
    let mut state = core.memory_state.lock();
    // Stop also emits Ended, but has not played the release through.
    if !state.stopping {
        report(core.store.clear_resume(release).map_err(Into::into));
        state.completed = Some(token);
    }
}

pub(crate) fn on_idle(core: &Core) {
    checkpoint(core, false, true);
    let token = core.now.borrow().item;
    let snapshot = snapshot(core, token, None);
    if let Some(pending) = snapshot {
        *core.pending.lock() = Some(pending);
    }
    core.memory_state.lock().stopping = false;
}

fn snapshot(core: &Core, token: Option<u64>, position_ms: Option<u64>) -> Option<Pending> {
    let (items, cursor) = {
        let player = core.player.lock();
        let q = player.queue();
        let at = q.position_of(token?)?;
        (q.items.clone(), at)
    };
    Some(Pending { items, cursor, position_ms: position_ms.unwrap_or_else(|| position(core, token)) })
}

fn position(core: &Core, token: Option<u64>) -> u64 {
    let now = core.now.borrow();
    let ms = now.anchor.filter(|a| Some(a.item) == token)
        .map(|a| a.seconds_at(meret_engine::clock::now_ns()) * 1000.0).unwrap_or(0.0) as u64;
    now.length_ms.map(|length| ms.min(length)).unwrap_or(ms)
}

fn save(core: &Core, token: Option<u64>, position_ms: Option<u64>, playing: bool, resume: bool) -> Result<()> {
    let (json, cursor, release, recording) = {
        let player = core.player.lock();
        let q = player.queue();
        let Some(at) = token.and_then(|token| q.position_of(token)) else { return Ok(()) };
        let json = serde_json::to_string(&q.items).map_err(|e| crate::CoreError::Query(e.to_string()))?;
        (json, at, q.items[at].release, q.items[at].recording)
    };
    let position_ms = position_ms.unwrap_or_else(|| position(core, token));
    let device = core.store.device_id()?;
    core.store.save_queue(json, cursor, position_ms, playing, &device)?;
    if resume && let (Some(release), Some(recording)) = (release, recording) {
        core.store.upsert_resume(release, recording, position_ms, &device)?;
    }
    Ok(())
}

fn report(result: Result<()>) {
    if let Err(error) = result {
        tracing::error!(%error, "could not save playback memory");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};
    use meret_engine::{Control, EngineEvent};
    use meret_model::{Idiom, RecordingId, ReleaseId};
    use meret_player::Zone;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use tokio::sync::broadcast;

    struct Running {
        core: Arc<Core>,
        pump: Option<std::thread::JoinHandle<()>>,
    }

    impl Running {
        fn open(dir: &Path, speed: f64) -> Self {
            let (scans, _) = crossbeam_channel::unbounded();
            let core = Arc::new(Core::new(CoreConfig { data_dir: dir.into(),
                output: OutputChoice::Null { speed }, contact: "test".into() }, scans).unwrap());
            restore(&core).unwrap();
            let pump = Some(crate::now::spawn_pump(core.clone()));
            Self { core, pump }
        }

        fn until(&self, events: &mut broadcast::Receiver<EngineEvent>, predicate: impl Fn(&EngineEvent) -> bool) -> EngineEvent {
            self.core.runtime.block_on(async {
                tokio::time::timeout(Duration::from_secs(5), async {
                    loop {
                        let event = events.recv().await.unwrap();
                        if predicate(&event) { return event; }
                    }
                }).await.expect("engine event before deadline")
            })
        }

        fn stop(&self, events: &mut broadcast::Receiver<EngineEvent>) {
            self.core.stop();
            self.until(events, |e| matches!(e, EngineEvent::Idle));
        }
    }

    impl Drop for Running {
        fn drop(&mut self) {
            self.core.engine.send(Control::Shutdown);
            self.pump.take().unwrap().join().unwrap();
        }
    }

    fn fixture() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("meret-core-memory-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let music = dir.join("music");
        std::fs::create_dir_all(&music).unwrap();
        for name in ["first.flac", "second.flac"] {
            std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"), music.join(name)).unwrap();
        }
        let store = meret_store::Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(move |tx| {
            tx.execute_batch("INSERT INTO release(id,title,idiom,rev) VALUES(1,'Test Release',5,1);
                INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
                INSERT INTO medium(id,edition_id,position) VALUES(1,1,1);
                INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'First Cue',6000,1),(2,'Second Cue',6000,1);
                INSERT INTO track(id,medium_id,position,recording_id,title,rev)
                    VALUES(1,1,1,1,'First Cue',1),(2,1,2,2,'Second Cue',1);")?;
            tx.execute("INSERT INTO root(id,label,path,kind) VALUES(1,'Music',?1,'local')", [music.to_string_lossy().as_ref()])?;
            for (id, name) in [(1, "first.flac"), (2, "second.flac")] {
                tx.execute("INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES(?1,1,?2,1,1,1)", rusqlite::params![id, name])?;
                tx.execute("INSERT INTO source(id,recording_id,track_id,kind,file_id,codec,lossless,sample_rate,bits,rev)
                    VALUES(?1,?1,?1,'file',?1,'FLAC',1,44100,16,1)", [id])?;
            }
            Ok(())
        }).unwrap();
        dir
    }

    #[test]
    fn stopped_queue_restores_now_paused_and_resumes_at_saved_score_position() {
        let dir = fixture();
        let running = Running::open(&dir, 1.0);
        let mut events = running.core.events();
        running.core.play_release(ReleaseId(1), 0).unwrap();
        running.until(&mut events, |e| matches!(e, EngineEvent::Anchor(_)));
        std::thread::sleep(Duration::from_secs(3));
        running.stop(&mut events);
        let saved = running.core.store.load_queue().unwrap().unwrap();
        assert!((2900..4000).contains(&saved.position_ms), "saved {} ms", saved.position_ms);
        assert!(!saved.playing);
        assert_eq!(running.core.resume_points(10).unwrap()[0].recording, RecordingId(1));
        drop(running);

        let running = Running::open(&dir, 1.0);
        let now = running.core.now.borrow().clone();
        assert_eq!(now.title, "First Cue");
        assert_eq!(now.length_ms, Some(6000));
        assert!(now.path.is_none(), "restoring does not open an audio device");
        assert_eq!(now.anchor.unwrap().rate, 0.0);
        assert_eq!(now.anchor.unwrap().position_frames, saved.position_ms);
        assert_eq!(running.core.queue().len(), 2);
        assert_eq!(running.core.up_next(10).1, 1);
        assert!(!running.core.local.state().playing);
        let mut events = running.core.events();
        assert!(events.try_recv().is_err());
        running.core.resume().unwrap();
        running.until(&mut events, |e| matches!(e, EngineEvent::Started { .. }));
        let EngineEvent::Anchor(anchor) = running.until(&mut events, |e| matches!(e, EngineEvent::Anchor(_))) else { unreachable!() };
        let started_ms = anchor.position_frames * 1000 / anchor.sample_rate as u64;
        assert!(started_ms.abs_diff(saved.position_ms) < 100, "resumed at {started_ms}, expected {}", saved.position_ms);
        running.stop(&mut events);
        drop(running);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_release_played_through_does_not_reappear_on_idle() {
        let dir = fixture();
        let running = Running::open(&dir, 30.0);
        let mut events = running.core.events();
        running.core.play_release(ReleaseId(1), 0).unwrap();
        running.until(&mut events, |e| matches!(e, EngineEvent::Idle));
        assert!(running.core.resume_points(10).unwrap().is_empty());
        assert!(!running.core.store.load_queue().unwrap().unwrap().playing);
        drop(running);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn pending_resume_obeys_every_idiom_and_from_start_and_pick_up() {
        let dir = fixture();
        for (idiom, saved_ms, expected_ms) in [
            (Idiom::Album, 3000, 0), (Idiom::Song, 3000, 0), (Idiom::Work, 3000, 0),
            (Idiom::Session, 3000, 0), (Idiom::Score, 3000, 3000), (Idiom::Set, 3000, 3000),
            (Idiom::Spoken, 5700, 700),
        ] {
            let store = meret_store::Store::open(&dir.join("library.db")).unwrap();
            let rows = store.release_page(ReleaseId(1)).unwrap().unwrap().tracks;
            let mut items = crate::queue_items(rows);
            for item in &mut items { item.idiom = idiom; }
            store.save_queue(serde_json::to_string(&items).unwrap(), 0, saved_ms, false, &store.device_id().unwrap()).unwrap();
            drop(store);
            let running = Running::open(&dir, 1.0);
            let mut events = running.core.events();
            running.core.resume().unwrap();
            let EngineEvent::Anchor(anchor) = running.until(&mut events, |e| matches!(e, EngineEvent::Anchor(_))) else { unreachable!() };
            let at_ms = anchor.position_frames * 1000 / anchor.sample_rate as u64;
            assert!(at_ms.abs_diff(expected_ms) < 100, "{idiom:?}: {at_ms} vs {expected_ms}");
            running.stop(&mut events);
            running.core.from_start().unwrap();
            let EngineEvent::Anchor(anchor) = running.until(&mut events, |e| matches!(e, EngineEvent::Anchor(_))) else { unreachable!() };
            assert!(anchor.position_frames * 1000 / (anchor.sample_rate as u64) < 100);
            running.stop(&mut events);
            drop(running);
        }
        let running = Running::open(&dir, 1.0);
        running.core.store.upsert_resume(ReleaseId(1), RecordingId(2), 2000, &running.core.store.device_id().unwrap()).unwrap();
        let mut events = running.core.events();
        running.core.pick_up(ReleaseId(1)).unwrap();
        assert_eq!(running.core.queue()[0].recording, Some(RecordingId(2)));
        let EngineEvent::Anchor(anchor) = running.until(&mut events, |e| matches!(e, EngineEvent::Anchor(_))) else { unreachable!() };
        assert!((anchor.position_frames * 1000 / anchor.sample_rate as u64).abs_diff(2000) < 100);
        running.stop(&mut events);
        assert!(!running.core.resume_points(10).unwrap().is_empty(), "stopping the final cue does not complete the release");
        drop(running);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
