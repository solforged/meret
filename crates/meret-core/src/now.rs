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
use meret_model::{ReleaseId, TrackId};
use meret_store::Artwork;

use crate::Core;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct NowState {
    pub item: Option<u64>,
    pub track: Option<TrackId>,
    pub release: Option<ReleaseId>,
    pub cover: Option<Artwork>,
    pub title: String,
    pub subtitle: String,
    /// Why this is playing, when something chose it: a Play something pick.
    pub why: Option<String>,
    pub anchor: Option<Anchor>,
    pub length_ms: Option<u64>,
    pub path: Option<SignalPath>,
    pub error: Option<String>,
}

pub(crate) fn spawn_pump(core: Arc<Core>) -> std::thread::JoinHandle<()> {
    thread::Builder::new()
        .name("meret-now".into())
        .spawn(move || {
            let events = core.engine.events().clone();
            loop {
                let e = match events.recv_timeout(std::time::Duration::from_secs(10)) {
                    Ok(e) => e,
                    Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                        crate::memory::on_tick(&core);
                        continue;
                    }
                    Err(crossbeam_channel::RecvTimeoutError::Disconnected) => break,
                };
                core.local.observe(&e);
                match &e {
                    EngineEvent::Started { item, path } => {
                        core.player.lock().started(*item);
                        let described = describe(&core, *item);
                        core.now.send_modify(|n| {
                            n.item = Some(*item);
                            n.path = Some(path.clone());
                            n.error = None;
                            n.track = described.track;
                            n.release = described.release;
                            n.cover = described.cover;
                            n.title = described.title;
                            n.subtitle = described.subtitle;
                            n.why = described.why;
                            n.length_ms = described.length_ms;
                        });
                        crate::listens::on_started(&core, *item);
                        crate::memory::on_started(&core, *item);
                    }
                    EngineEvent::OutputChanged { path } => core.now.send_modify(|n| n.path = Some(path.clone())),
                    EngineEvent::Anchor(a) => {
                        core.now.send_modify(|n| n.anchor = Some(*a));
                        crate::memory::on_anchor(&core, a);
                    }
                    EngineEvent::Ended { item } => {
                        let mut player = core.player.lock();
                        player.ended(*item);
                        if let Some(error) = player.take_error() {
                            core.now.send_modify(|n| n.error = Some(error));
                        }
                        drop(player);
                        crate::listens::on_ended(&core, *item);
                        crate::memory::on_ended(&core, *item);
                    }
                    EngineEvent::Idle => {
                        let mut player = core.player.lock();
                        player.idle();
                        let error = player.take_error();
                        core.now.send_modify(|n| {
                            if let Some(a) = &mut n.anchor {
                                a.position_frames = (a.seconds_at(meret_engine::clock::now_ns()) * a.sample_rate as f64) as u64;
                                a.at_ns = meret_engine::clock::now_ns();
                                a.rate = 0.0;
                            }
                            if let Some(error) = error {
                                n.error = Some(error);
                            }
                        });
                        drop(player);
                        crate::listens::on_idle(&core);
                        crate::memory::on_idle(&core);
                    }
                    EngineEvent::Error { message, .. } => core.now.send_modify(|n| n.error = Some(message.clone())),
                }
                let _ = core.events.send(e);
            }
        })
        .expect("spawn now pump")
}

/// Library metadata for a track, or the file name for a loose file.
fn describe(core: &Core, token: u64) -> NowState {
    let item = {
        let player = core.player.lock();
        let q = player.queue();
        q.position_of(token).map(|i| q.items[i].clone())
    };
    let Some(item) = item else { return Default::default() };
    describe_item(core, &item)
}

pub(crate) fn describe_item(core: &Core, item: &meret_player::QueueItem) -> NowState {
    if let Some(track) = item.track
        && let Ok(rows) = core.store.track_rows(&[track])
        && let Some(r) = rows.into_iter().next()
    {
        let subtitle = [r.artist.as_deref(), Some(r.album.as_str())].into_iter().flatten().collect::<Vec<_>>().join(" · ");
        let cover = core.store.release_art(&[r.release]).ok().and_then(|mut a| a.remove(&r.release));
        return NowState {
            track: Some(track),
            release: Some(r.release),
            cover,
            title: r.title,
            subtitle,
            why: item.why.clone(),
            length_ms: r.length_ms,
            ..Default::default()
        };
    }
    let path = Path::new(item.uri.strip_prefix("file://").unwrap_or(&item.uri));
    let title = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let subtitle = path.parent().map(|p| p.display().to_string()).unwrap_or_default();
    NowState { track: item.track, title, subtitle, why: item.why.clone(), ..Default::default() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};
    use meret_model::EntityKind;
    use rusqlite::params;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn describing_a_library_track_reads_its_release_cover() {
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("meret-now-{}-{t}", std::process::id()));
        std::fs::create_dir_all(dir.join("music")).unwrap();
        let track = dir.join("music/tone.flac");
        std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"), &track).unwrap();
        let (scans, _) = crossbeam_channel::unbounded();
        let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: String::new() }, scans).unwrap();
        let root = meret_library::add_root(&core.store, &dir.join("music")).unwrap();
        meret_library::scan(&core.store, root, &|_| {}).unwrap();
        let row = core.store.track_rows(&core.store.load_columns().unwrap().track).unwrap().remove(0);
        let release = row.release;
        core.store.writer.write(move |tx| {
            tx.execute("INSERT INTO artwork (hash, light, light_wash, light_dim) VALUES (?1, ?2, ?3, ?4)",
                params![&[1u8; 32], 0xffcc8844i64, 0x14cc8844i64, 0x55cc8844i64])?;
            tx.execute("INSERT INTO entity_artwork (entity_kind, entity_id, hash) VALUES (?1, ?2, ?3)",
                params![EntityKind::Release as i64, release.0, &[1u8; 32]])?;
            Ok(())
        }).unwrap();
        core.play_release(release, 0).unwrap();
        let now = describe(&core, core.queue()[0].token);
        assert_eq!(now.track, Some(row.track));
        assert_eq!(now.release, Some(release));
        assert_eq!(now.cover.unwrap().light, Some(0xffcc8844));
        assert_eq!(now.title, row.title);
        core.stop();
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
