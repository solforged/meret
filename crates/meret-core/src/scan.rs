//! The scan worker: one background thread that loads the hot columns,
//! scans roots one at a time, and reloads the columns after each scan.
//! Never an engine thread, so a scan can't stall playback.

use std::sync::Arc;
use std::thread;
use std::time::Instant;

use crossbeam_channel::Receiver;
use meret_model::RootId;
use tokio::sync::oneshot;

use crate::{Core, status};

pub(crate) enum ScanRequest {
    /// Rebuild the hot columns from SQLite.
    LoadColumns,
    Root(RootId),
    /// Rescan every root the library knows.
    AllRoots,
    /// Answered once everything queued before it is done.
    Settled(oneshot::Sender<()>),
}

pub(crate) fn spawn_worker(core: Arc<Core>, requests: Receiver<ScanRequest>) {
    thread::Builder::new()
        .name("meret-scan".into())
        .spawn(move || {
            while let Ok(r) = requests.recv() {
                match r {
                    ScanRequest::LoadColumns => reload(&core),
                    ScanRequest::Root(root) => scan(&core, root),
                    ScanRequest::AllRoots => match meret_library::roots(&core.store) {
                        Ok(roots) => roots.into_iter().for_each(|r| scan(&core, r.id)),
                        Err(e) => tracing::error!(error = %e, "could not list roots"),
                    },
                    ScanRequest::Settled(done) => {
                        let _ = done.send(());
                    }
                }
            }
        })
        .expect("spawn scan worker");
}

fn scan(core: &Core, root: RootId) {
    let t = Instant::now();
    let progress = |p: meret_library::ScanProgress| core.status.send_modify(|s| status::set_scan(s, Some(p)));
    match meret_library::scan(&core.store, root, &progress) {
        Ok(report) => {
            tracing::info!(root = root.0, ?report, took = ?t.elapsed(), "scanned");
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
    match core.store.load_columns() {
        Ok(cols) => {
            let tracks = cols.len() as u64;
            *core.columns.write() = cols;
            core.status.send_modify(|s| status::set_library(s, tracks));
        }
        Err(e) => tracing::error!(error = %e, "could not load the hot columns"),
    }
}
