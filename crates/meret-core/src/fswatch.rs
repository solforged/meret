//! Keeps the library current with FSEvents. At launch, roots with a usable
//! mark replay what changed since the last run, and the rest are walked.
//! While Meret runs, a burst of changes is gathered, then the changed
//! folders are walked again.

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{Receiver, RecvTimeoutError, Sender};
use meret_library::watch::{self, Changes, Event, SINCE_NOW, Watcher, flags};

use crate::Core;
use crate::scan::ScanRequest;

/// A burst ends after this long without changes, or this long after it began.
const QUIET: Duration = Duration::from_millis(700);
const LONGEST: Duration = Duration::from_secs(5);

pub(crate) enum Message {
    Events(Vec<Event>),
    /// A root was added or removed.
    Roots,
}

/// Queues a walk of each root FSEvents can't vouch for, and a replay of the
/// rest, then starts watching.
pub(crate) fn start(core: &Arc<Core>) {
    let marks = match watch::marks(&core.store) {
        Ok(marks) => marks,
        Err(error) => {
            tracing::error!(%error, "could not read the FSEvents marks; walking every root");
            let _ = core.scans.send(ScanRequest::AllRoots);
            return;
        }
    };
    let mut since = SINCE_NOW;
    for mark in &marks {
        match mark.id {
            Some(id) if mark.uuid.is_some() && watch::database_uuid(&mark.path) == mark.uuid => since = since.min(id),
            _ => {
                tracing::info!(root = mark.root.0, "no FSEvents history to resume; walking");
                let _ = core.scans.send(ScanRequest::Root(mark.root));
            }
        }
    }
    let replay = (since != SINCE_NOW).then(|| {
        let (done, replayed) = crossbeam_channel::bounded(1);
        let _ = core.scans.send(ScanRequest::Replay(replayed));
        done
    });
    let (tx, rx) = crossbeam_channel::unbounded();
    let _ = core.fswatch.set(tx.clone());
    let core = core.clone();
    thread::Builder::new()
        .name("meret-fswatch".into())
        .spawn(move || run(&core, since, replay, &tx, &rx))
        .expect("spawn FSEvents watcher");
}

fn run(core: &Core, since: u64, mut replay: Option<Sender<Changes>>, tx: &Sender<Message>, rx: &Receiver<Message>) {
    // Where a restarted stream resumes, so nothing between two streams is lost.
    let mut last = if since == SINCE_NOW { watch::current_event_id() } else { since };
    let mut watcher = open(core, since, tx);
    if watcher.is_none() {
        // Dropping the sender makes the scan worker walk every root instead.
        replay = None;
    }
    let mut pending: Vec<Event> = vec![];
    while let Ok(first) = rx.recv() {
        let mut reopen = false;
        let mut take = |message, pending: &mut Vec<Event>| match message {
            Message::Events(events) => pending.extend(events),
            Message::Roots => reopen = true,
        };
        take(first, &mut pending);
        let began = Instant::now();
        while began.elapsed() < LONGEST {
            match rx.recv_timeout(QUIET) {
                Ok(message) => take(message, &mut pending),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
        let history_done = pending.iter().any(|e| e.flags & flags::HISTORY_DONE != 0);
        // The replay goes to the scan worker as one batch, so marks only move forward.
        if !pending.is_empty() && (replay.is_none() || history_done) {
            let roots: Vec<_> = match watch::marks(&core.store) {
                Ok(marks) => marks.into_iter().map(|m| (m.root, m.path)).collect(),
                Err(error) => {
                    tracing::error!(%error, "could not list roots");
                    vec![]
                }
            };
            let changes = watch::plan(&roots, &pending);
            pending.clear();
            last = last.max(changes.through.unwrap_or(last));
            match replay.take() {
                Some(done) => {
                    let _ = done.send(changes);
                }
                None if changes.full.is_empty() && changes.dirs.is_empty() && changes.through.is_none() => {}
                None => {
                    let _ = core.scans.send(ScanRequest::Changes(changes));
                }
            }
        }
        if reopen {
            drop(watcher.take());
            watcher = open(core, last, tx);
        }
    }
}

fn open(core: &Core, since: u64, tx: &Sender<Message>) -> Option<Watcher> {
    let paths: Vec<_> = match watch::marks(&core.store) {
        Ok(marks) => marks.into_iter().map(|m| m.path).collect(),
        Err(error) => {
            tracing::error!(%error, "could not list roots");
            return None;
        }
    };
    let tx = tx.clone();
    let watcher = Watcher::start(&paths, since, move |events| {
        let _ = tx.send(Message::Events(events));
    });
    tracing::info!(?paths, since, watching = watcher.is_some(), "FSEvents");
    watcher
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};

    const TONE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac");

    /// A core with a scan worker; `watching` also starts the FSEvents side,
    /// as `crate::start` does.
    fn launch(dir: &std::path::Path, watching: bool) -> Arc<Core> {
        let (scans, requests) = crossbeam_channel::unbounded();
        let config = CoreConfig { data_dir: dir.into(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() };
        let core = Arc::new(Core::new(config, scans).unwrap());
        crate::scan::spawn_worker(core.clone(), requests);
        let _ = core.scans.send(ScanRequest::LoadColumns);
        if watching {
            start(&core);
        } else {
            let _ = core.scans.send(ScanRequest::AllRoots);
        }
        core.runtime.block_on(core.scans_settled()).unwrap();
        core
    }

    fn walked_at(core: &Core) -> Option<i64> {
        core.store.read(|c| c.query_row("SELECT last_walk_at FROM root", [], |r| r.get(0))).unwrap()
    }

    #[test]
    fn a_launch_replays_what_changed_while_closed_and_a_running_core_sees_new_files() {
        let dir = std::env::temp_dir().join(format!("meret-fswatch-{}", std::process::id()));
        let music = dir.join("music");
        // Folders made up front, so later changes are inside them, not the root.
        for folder in ["A", "B", "C"] {
            std::fs::create_dir_all(music.join(folder)).unwrap();
        }
        std::fs::copy(TONE, music.join("A/1.flac")).unwrap();
        let store = meret_store::Store::open(&dir.join("library.db")).unwrap();
        meret_library::add_root(&store, &music).unwrap();
        drop(store);

        // A walk records where FSEvents can resume from. This run doesn't
        // watch, so what follows happens while nobody does.
        let first = launch(&dir, false);
        assert_eq!(first.columns.read().len(), 1);
        let walked = walked_at(&first);
        assert!(walked.is_some());
        drop(first);

        std::fs::copy(TONE, music.join("B/2.flac")).unwrap();
        let second = launch(&dir, true);
        assert_eq!(second.columns.read().len(), 2, "the replay found B/2.flac");
        assert_eq!(walked_at(&second), walked, "resumed, not walked");

        std::fs::copy(TONE, music.join("C/3.flac")).unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while second.columns.read().len() < 3 {
            assert!(Instant::now() < deadline, "C/3.flac never showed up");
            thread::sleep(Duration::from_millis(100));
        }
        assert_eq!(walked_at(&second), walked);
        std::fs::remove_dir_all(dir).ok();
    }
}
