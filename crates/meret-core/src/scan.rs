//! The scan worker: one background thread that loads the hot columns,
//! scans roots one at a time, and reloads the columns after each scan.
//! Never an engine thread, so a scan can't stall playback.

use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::Receiver;
use meret_library::watch::Changes;
use meret_model::RootId;
use tokio::sync::oneshot;

use crate::{Core, status};

/// How long the startup replay of FSEvents history may take before every
/// root is walked instead.
const REPLAY_WAIT: Duration = Duration::from_secs(10);

pub(crate) enum ScanRequest {
    /// Rebuild the hot columns from SQLite.
    LoadColumns,
    Root(RootId),
    Remove(RootId, crossbeam_channel::Sender<crate::Result<()>>),
    /// Rescan every root the library knows.
    AllRoots,
    /// What FSEvents saw: folders to walk again, roots to walk whole.
    Changes(Changes),
    /// At launch: what changed since the last run, once FSEvents has replayed
    /// it. Requests queued later, a `Settled` among them, wait for it.
    Replay(Receiver<Changes>),
    /// Answered once everything queued before it is done.
    Settled(oneshot::Sender<()>),
}

pub(crate) fn spawn_worker(core: Arc<Core>, requests: Receiver<ScanRequest>) {
    thread::Builder::new()
        .name("meret-scan".into())
        .spawn(move || {
            while let Ok(r) = requests.recv() {
                handle(&core, r);
            }
        })
        .expect("spawn scan worker");
}

pub(super) fn handle(core: &Core, request: ScanRequest) {
    match request {
        ScanRequest::LoadColumns => reload(core),
        ScanRequest::Root(root) => scan(core, root, &[]),
        ScanRequest::Remove(root, done) => {
            let result = meret_library::remove_root(&core.store, root).map_err(crate::CoreError::from)
                .and_then(|()| reload_result(core));
            let _ = done.send(result);
        }
        ScanRequest::AllRoots => all_roots(core),
        ScanRequest::Changes(changes) => apply(core, changes),
        ScanRequest::Replay(replayed) => match replayed.recv_timeout(REPLAY_WAIT) {
            Ok(changes) => apply(core, changes),
            Err(error) => {
                tracing::warn!(%error, "no FSEvents replay; walking every root");
                all_roots(core);
            }
        },
        ScanRequest::Settled(done) => {
            let _ = done.send(());
        }
    }
}

fn all_roots(core: &Core) {
    match meret_library::roots(&core.store) {
        Ok(roots) => roots.into_iter().for_each(|r| scan(core, r.id, &[])),
        Err(e) => tracing::error!(error = %e, "could not list roots"),
    }
}

/// Walks what changed, then records every root walked whole before as
/// current to the batch's last event.
fn apply(core: &Core, changes: Changes) {
    tracing::info!(?changes, "applying file changes");
    for root in &changes.full {
        scan(core, *root, &[]);
    }
    for (root, dirs) in &changes.dirs {
        scan(core, *root, dirs);
    }
    #[cfg(target_os = "macos")]
    if let Some(through) = changes.through {
        let marks = meret_library::watch::marks(&core.store).map(|marks| marks.into_iter()
            // A root never walked whole has nothing to be current to.
            .filter(|mark| mark.id.is_some())
            .filter_map(|mark| Some((mark.root, through, meret_library::watch::database_uuid(&mark.path)?)))
            .collect())
            .and_then(|marks| meret_library::watch::set_marks(&core.store, marks));
        if let Err(error) = marks {
            tracing::error!(%error, "could not record the FSEvents position");
        }
    }
}

/// The whole root when `dirs` is empty.
fn scan(core: &Core, root: RootId, dirs: &[String]) {
    let t = Instant::now();
    let progress = |p: meret_library::ScanProgress| core.status.send_modify(|s| status::set_scan(s, Some(p)));
    let scanned = if dirs.is_empty() {
        meret_library::scan(&core.store, root, &progress)
    } else {
        meret_library::rescan_dirs(&core.store, root, dirs, &progress)
    };
    match scanned {
        Ok(report) => {
            tracing::info!(root = root.0, ?dirs, ?report, took = ?t.elapsed(), "scanned");
            let t = Instant::now();
            match meret_library::covers(&core.store, &core.art_dir(), &progress) {
                Ok(report) => {
                    let mut total = core.cover_report.lock();
                    total.checked += report.checked;
                    total.found += report.found;
                    total.files += report.files;
                    total.unreadable += report.unreadable;
                    tracing::info!(?report, took = ?t.elapsed(), "read covers");
                }
                Err(e) => tracing::error!(error = %e, "cover scan failed"),
            }
        }
        Err(e) => tracing::error!(root = root.0, error = %e, "scan failed"),
    }
    core.status.send_modify(|s| status::set_scan(s, None));
    reload(core);
}

/// Swaps in freshly loaded columns; the write lock is held only for the swap.
fn reload(core: &Core) {
    if let Err(e) = reload_result(core) {
        tracing::error!(error = %e, "could not load the hot columns");
    }
}

fn reload_result(core: &Core) -> crate::Result<()> {
    let analysis_write = core.analysis_write.lock();
    let cols = core.store.load_columns()?;
    let tracks = cols.len() as u64;
    *core.columns.write() = cols;
    drop(analysis_write);
    core.status.send_modify(|s| status::set_library(s, tracks));
    crate::lookups::seed(core);
    if let Err(error) = crate::analysis::seed(core) {
        tracing::error!(%error, "could not seed analysis jobs");
    }
    Ok(())
}
