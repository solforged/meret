//! The event pump's single open listen. The player lock is released before
//! any store write; a matching Ended or Idle takes the open row exactly once.
//! Memory checkpoints write how far it got while it plays, so quitting or
//! crashing mid-track keeps the listen. Resuming the saved queue after a
//! restart continues the listen it names rather than counting a second play.

use meret_model::{ListenUid, RecordingId, TrackId};

use crate::Core;

pub(crate) struct Open {
    uid: ListenUid,
    item: u64,
    track: TrackId,
    recording: RecordingId,
    started_at: i64,
    /// Already added to the hot columns' plays.
    counted: bool,
}

/// The saved queue's open listen, continued if its item is the next to start.
pub(crate) struct Carried {
    pub uid: ListenUid,
    pub recording: RecordingId,
}

pub(crate) fn on_started(core: &Core, token: u64) {
    if core.open_listen.lock().as_ref().is_some_and(|open| open.item == token) {
        return;
    }
    // A replacement can start without an Idle between the two queues.
    finish(core, None);
    let carried = core.carried_listen.lock().take();
    let item = {
        let player = core.player.lock();
        let queue = player.queue();
        queue.position_of(token).map(|at| {
            let item = &queue.items[at];
            (item.track, item.recording, item.from_stop)
        })
    };
    let Some((Some(track), Some(recording), from_stop)) = item else { return };
    if let Some(carried) = carried.filter(|c| c.recording == recording) {
        match core.store.listen(carried.uid) {
            Ok(Some((saved, started_at, counted))) if saved == recording => {
                *core.open_listen.lock() = Some(Open { uid: carried.uid, item: token, track, recording, started_at, counted });
                return;
            }
            Ok(_) => {}
            Err(error) => tracing::error!(%error, item = token, "could not continue listen"),
        }
    }
    let uid = ListenUid::new();
    let started_at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    let result = core.store.listen_source(track).and_then(|source| {
        core.store.start_listen(uid, recording, source, "local".into(), started_at, from_stop, core.device_id.clone())
    });
    match result {
        Ok(()) => *core.open_listen.lock() = Some(Open { uid, item: token, track, recording, started_at, counted: false }),
        Err(error) => tracing::error!(%error, item = token, "could not start listen"),
    }
}

pub(crate) fn on_ended(core: &Core, item: u64) {
    finish(core, Some(item));
}

pub(crate) fn on_idle(core: &Core) {
    finish(core, None);
}

/// The open listen, if it belongs to `token`; saved with the queue.
pub(crate) fn open_uid(core: &Core, token: Option<u64>) -> Option<ListenUid> {
    core.open_listen.lock().as_ref().filter(|open| Some(open.item) == token).map(|open| open.uid)
}

/// Writes how far the open listen got without closing it.
pub(crate) fn progress(core: &Core) {
    if let Some(open) = core.open_listen.lock().as_mut() {
        write(core, open);
    }
}

fn finish(core: &Core, item: Option<u64>) {
    let open = {
        let mut open = core.open_listen.lock();
        if item.is_some_and(|item| open.as_ref().is_none_or(|open| open.item != item)) {
            return;
        }
        open.take()
    };
    if let Some(mut open) = open {
        write(core, &mut open);
    }
}

/// Writes the position the anchor gives for the listen's item. Without an
/// anchor for it, what was written last stands.
fn write(core: &Core, open: &mut Open) {
    let Some(played_ms) = core.now.borrow().anchor.filter(|a| a.item == open.item)
        .map(|a| (a.seconds_at(meret_engine::clock::now_ns()) * 1000.0) as u64) else { return };
    match core.store.update_listen(open.uid, played_ms) {
        Ok(true) if !open.counted => {
            open.counted = true;
            core.columns.write().record_play(open.track, open.started_at / 1000);
            core.status.send_modify(|status| status.library_version += 1);
        }
        Ok(_) => {}
        Err(error) => tracing::error!(%error, item = open.item, recording = open.recording.0, "could not write listen"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};
    use meret_engine::EngineEvent;
    use std::time::{Duration, Instant};

    fn drive(core: &Core, skip_at_ms: Option<u64>) {
        let deadline = Instant::now() + Duration::from_secs(12);
        core.now.send_modify(|now| now.anchor = None);
        let mut skipped = false;
        loop {
            assert!(Instant::now() < deadline, "playback did not become idle");
            if let Some(ms) = skip_at_ms
                && !skipped
                && core.now.borrow().anchor.is_some_and(|a| a.seconds_at(meret_engine::clock::now_ns()) * 1000.0 >= ms as f64)
            {
                core.next().unwrap();
                skipped = true;
            }
            let event = match core.engine.events().recv_timeout(Duration::from_millis(10)) {
                Ok(event) => event,
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => continue,
                Err(error) => panic!("engine stopped: {error}"),
            };
            core.local.observe(&event);
            match event {
                EngineEvent::Started { item, .. } => {
                    core.player.lock().started(item);
                    core.now.send_modify(|now| now.item = Some(item));
                    on_started(core, item);
                }
                EngineEvent::Anchor(anchor) => core.now.send_modify(|now| now.anchor = Some(anchor)),
                EngineEvent::Ended { item } => {
                    core.player.lock().ended(item);
                    on_ended(core, item);
                    on_ended(core, item); // Repeated terminal notifications cannot double-count.
                }
                EngineEvent::Idle => {
                    on_idle(core);
                    break;
                }
                EngineEvent::Error { message, .. } => panic!("engine error: {message}"),
                EngineEvent::OutputChanged { .. } => {}
            }
        }
    }

    #[test]
    fn null_playback_counts_a_complete_track_but_not_a_one_second_skip_or_a_loose_file() {
        let dir = std::env::temp_dir().join(format!("meret-core-listens-{}", ListenUid::new()));
        std::fs::create_dir_all(dir.join("music")).unwrap();
        let file = dir.join("music/tone.flac");
        std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"), &file).unwrap();
        let (scans, _) = crossbeam_channel::unbounded();
        let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 4.0 }, contact: "test".into() }, scans).unwrap();
        let root = meret_library::add_root(&core.store, &dir.join("music")).unwrap();
        meret_library::scan(&core.store, root, &|_| {}).unwrap();
        *core.columns.write() = core.store.load_columns().unwrap();
        let track = core.columns.read().track[0];
        let release = core.store.track_rows(&[track]).unwrap()[0].release;
        let version = core.status.borrow().library_version;
        core.play_release(release, 0).unwrap();
        drive(&core, None);
        let history = core.store.history(10).unwrap();
        assert_eq!(history.len(), 1);
        assert!(history[0].counted);
        assert_eq!(core.columns.read().plays, [1]);
        assert_eq!(core.store.load_columns().unwrap().plays, [1]);
        assert_eq!(core.columns.read().last_played[0], history[0].started_at / 1000);
        assert!(core.status.borrow().library_version > version);
        let version = core.status.borrow().library_version;
        core.play_release(release, 0).unwrap();
        drive(&core, Some(1_000));
        let history = core.store.history(10).unwrap();
        assert_eq!(history.len(), 2);
        assert!(!history[0].counted);
        assert!((1_000..1_250).contains(&history[0].played_ms), "{}", history[0].played_ms);
        assert_eq!(core.columns.read().plays, [1]);
        assert_eq!(core.status.borrow().library_version, version);
        core.play_file(&file).unwrap();
        drive(&core, Some(1_000));
        assert_eq!(core.store.history(10).unwrap().len(), 2);
        assert!(core.open_listen.lock().is_none());
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
