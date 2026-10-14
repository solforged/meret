//! Now: what's playing, where, and through what. Fed by engine events.
//!
//! The pump is the only reader of the engine's events. It keeps the local
//! zone's state, moves the queue along as items end (which loads the next
//! item early, for a gapless join), fills in Now, and rebroadcasts each
//! event for anything else that listens.

use std::path::Path;
use std::sync::Arc;
use std::thread;

use meret_engine::{Anchor, EngineEvent};
use meret_model::signal::SignalPath;

use crate::Core;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct NowState {
    pub item: Option<u64>,
    pub title: String,
    pub subtitle: String,
    pub anchor: Option<Anchor>,
    pub length_ms: Option<u64>,
    pub path: Option<SignalPath>,
    pub error: Option<String>,
}

pub(crate) fn spawn_pump(core: Arc<Core>) {
    thread::Builder::new()
        .name("meret-now".into())
        .spawn(move || {
            let events = core.engine.events().clone();
            while let Ok(e) = events.recv() {
                core.local.observe(&e);
                match &e {
                    EngineEvent::Started { item, path } => {
                        core.player.lock().started(*item);
                        let (title, subtitle, length_ms) = describe(&core, *item);
                        core.now.send_modify(|n| {
                            n.item = Some(*item);
                            n.path = Some(path.clone());
                            n.error = None;
                            n.title = title;
                            n.subtitle = subtitle;
                            n.length_ms = length_ms;
                        });
                    }
                    EngineEvent::Anchor(a) => core.now.send_modify(|n| n.anchor = Some(*a)),
                    EngineEvent::Ended { item } => {
                        let mut player = core.player.lock();
                        player.ended(*item);
                        if let Some(error) = player.take_error() {
                            core.now.send_modify(|n| n.error = Some(error));
                        }
                    }
                    EngineEvent::Idle => {
                        let mut player = core.player.lock();
                        player.idle();
                        let error = player.take_error();
                        core.now.send_modify(|n| {
                            if let Some(a) = &mut n.anchor {
                                a.rate = 0.0;
                            }
                            if let Some(error) = error {
                                n.error = Some(error);
                            }
                        });
                    }
                    EngineEvent::Error { message, .. } => core.now.send_modify(|n| n.error = Some(message.clone())),
                }
                let _ = core.events.send(e);
            }
        })
        .expect("spawn now pump");
}

/// Title, "artist · album" and length for a queue item: from the library
/// for a track, from the file name for a loose file.
fn describe(core: &Core, token: u64) -> (String, String, Option<u64>) {
    let item = {
        let player = core.player.lock();
        let q = player.queue();
        q.position_of(token).map(|i| q.items[i].clone())
    };
    let Some(item) = item else { return Default::default() };
    if let Some(track) = item.track
        && let Ok(rows) = core.store.track_rows(&[track])
        && let Some(r) = rows.into_iter().next()
    {
        let subtitle = [r.artist.as_deref(), Some(r.album.as_str())].into_iter().flatten().collect::<Vec<_>>().join(" · ");
        return (r.title, subtitle, r.length_ms);
    }
    let path = Path::new(item.uri.strip_prefix("file://").unwrap_or(&item.uri));
    let title = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let subtitle = path.parent().map(|p| p.display().to_string()).unwrap_or_default();
    (title, subtitle, None)
}
