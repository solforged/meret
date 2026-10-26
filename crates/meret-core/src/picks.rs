//! Play something (plate 09, navigation.md): ranked picks that always say
//! why. Until habits, leads and the sky exist, the ranking comes from
//! listens and trails alone: something dormant, then something your latest
//! trail reached but you never played through, then something never played,
//! rotating by the day so the same pick holds all day and the CLI agrees
//! with the app.

use meret_model::{EntityRef, ReleaseId};

use crate::{Core, Result};

const DORMANT_MS: i64 = 180 * 86_400_000;
const DAY_MS: i64 = 86_400_000;
/// How far back Play something looks for a trail you left something unplayed on.
const RECENT_TRAILS: usize = 5;

#[derive(Clone, Debug, PartialEq)]
pub enum Why {
    /// Five counted plays, then none for half a year.
    Dormant { plays: u64, last_played_ms: i64 },
    /// Reached on a recent trail (`latest` for the newest), never played through.
    FromTrail { trail: String, latest: bool },
    /// No counted play at all; `added_ms` is when its newest file arrived.
    NeverPlayed { added_ms: Option<i64> },
}

#[derive(Clone, Debug, PartialEq)]
pub struct Pick {
    pub release: ReleaseId,
    pub why: Why,
}

impl Core {
    /// Up to `limit` picks, best first, never the same release twice and
    /// never the one loaded in the queue: Now already shows that.
    pub fn picks(&self, limit: usize, now_ms: i64) -> Result<Vec<Pick>> {
        let mut picks: Vec<Pick> = Vec::with_capacity(limit);
        let loaded = self.loaded_release();
        let push = |picks: &mut Vec<Pick>, release: ReleaseId, why: Why| {
            if picks.len() < limit && Some(release) != loaded && !picks.iter().any(|p| p.release == release) {
                picks.push(Pick { release, why });
            }
        };
        for dormant in self.store.dormant_before(now_ms - DORMANT_MS, limit as u32)? {
            push(&mut picks, dormant.release, Why::Dormant { plays: dormant.plays, last_played_ms: dormant.last_played });
        }
        for (i, (title, releases)) in self.recent_trail_releases()?.into_iter().enumerate() {
            for release in releases {
                if picks.len() >= limit {
                    break;
                }
                if self.store.release_plays(release)?.0 == 0 && self.store.release_page(release)?.is_some_and(|p| p.tracks.iter().any(|t| t.path.is_some())) {
                    push(&mut picks, release, Why::FromTrail { trail: title.clone(), latest: i == 0 });
                }
            }
        }
        let never = self.store.never_played()?;
        if !never.is_empty() {
            let start = (now_ms / DAY_MS).rem_euclid(never.len() as i64) as usize;
            for i in 0..never.len() {
                if picks.len() >= limit {
                    break;
                }
                let (release, added_ms) = never[(start + i) % never.len()];
                push(&mut picks, release, Why::NeverPlayed { added_ms });
            }
        }
        Ok(picks)
    }

    /// The newest trails' titles and the releases each reached, newest trail
    /// and newest stop first.
    fn recent_trail_releases(&self) -> Result<Vec<(String, Vec<ReleaseId>)>> {
        let recent: Vec<_> = {
            let history = self.trail.lock();
            history.entries().rev().take(RECENT_TRAILS).map(|(trail, _)| {
                let stops = trail.stops();
                let mut releases: Vec<ReleaseId> = Vec::new();
                for stop in stops.iter().rev() {
                    if let EntityRef::Release(id) = stop.entity && !releases.contains(&id) {
                        releases.push(id);
                    }
                }
                (trail.name.clone(), stops.first().map(|s| (s.entity, trail.root_query.clone())), releases)
            }).collect()
        };
        recent.into_iter().map(|(name, root, releases)| {
            let title = match (name, root) {
                (Some(name), _) => name,
                (None, Some((EntityRef::Search, query))) => crate::search_title(query.as_deref().unwrap_or_default()),
                (None, Some((EntityRef::Release(id), _))) => self.store.release_title(id)?.unwrap_or_else(|| "gone".into()),
                (None, Some((EntityRef::Agent(id), _))) => self.store.agent_name(id)?.unwrap_or_else(|| "gone".into()),
                _ => "gone".into(),
            };
            Ok((title, releases))
        }).collect()
    }

    /// Plays a pick from the top, with its why on every queued item so Now
    /// can say it.
    pub fn play_pick(&self, release: ReleaseId, why: String) -> Result<()> {
        let page = self.store.release_page(release)?.ok_or_else(|| crate::CoreError::Query("that release is gone".into()))?;
        let mut items = crate::queue_items(page.tracks);
        for item in &mut items {
            item.why = Some(why.clone());
        }
        self.play(items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};
    use meret_model::Idiom;
    use meret_player::QueueItem;

    /// Two never-played one-track releases with real files.
    fn core() -> (std::path::PathBuf, Core) {
        let dir = std::env::temp_dir().join(format!("meret-picks-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let music = dir.join("music");
        std::fs::create_dir_all(&music).unwrap();
        for name in ["first.flac", "second.flac"] {
            std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"), music.join(name)).unwrap();
        }
        let (scans, _) = crossbeam_channel::unbounded();
        let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() }, scans).unwrap();
        core.store.writer.write(move |tx| {
            tx.execute_batch("INSERT INTO release(id,title,idiom,rev) VALUES(1,'Release One',5,1),(2,'Release Two',5,1);
                INSERT INTO edition(id,release_id,rev) VALUES(1,1,1),(2,2,1);
                INSERT INTO medium(id,edition_id,position) VALUES(1,1,1),(2,2,1);
                INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'First Cue',6000,1),(2,'Second Cue',6000,1);
                INSERT INTO track(id,medium_id,position,recording_id,title,rev) VALUES(1,1,1,1,'First Cue',1),(2,2,1,2,'Second Cue',1);")?;
            tx.execute("INSERT INTO root(id,label,path,kind) VALUES(1,'Music',?1,'local')", [music.to_string_lossy().as_ref()])?;
            for (id, name) in [(1, "first.flac"), (2, "second.flac")] {
                tx.execute("INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES(?1,1,?2,1,1,1)", rusqlite::params![id, name])?;
                tx.execute("INSERT INTO source(id,recording_id,track_id,kind,file_id,codec,lossless,sample_rate,bits,rev)
                    VALUES(?1,?1,?1,'file',?1,'FLAC',1,44100,16,1)", [id])?;
            }
            Ok(())
        }).unwrap();
        (dir, core)
    }

    #[test]
    fn the_loaded_release_is_never_a_pick() {
        let (dir, core) = core();
        let releases = |picks: Vec<Pick>| picks.into_iter().map(|p| p.release).collect::<Vec<_>>();
        let mut both = releases(core.picks(10, 0).unwrap());
        both.sort();
        assert_eq!(both, [ReleaseId(1), ReleaseId(2)]);
        assert!(core.picks(10, 0).unwrap().iter().all(|p| matches!(p.why, Why::NeverPlayed { .. })));

        // Restored from the last run, paused at Release One.
        let item = QueueItem { token: 1, uri: format!("file://{}", dir.join("music/first.flac").display()), gain_db: 0.0,
            track: Some(meret_model::TrackId(1)), recording: Some(meret_model::RecordingId(1)), release: Some(ReleaseId(1)),
            work: None, idiom: Idiom::Score, from_stop: None, why: None };
        core.store.save_queue(serde_json::to_string(&[item]).unwrap(), 0, 2000, false, &core.device_id, None).unwrap();
        crate::memory::restore(&core).unwrap();
        assert_eq!(core.loaded_release(), Some(ReleaseId(1)));
        assert_eq!(releases(core.picks(10, 0).unwrap()), [ReleaseId(2)]);
        assert_eq!(releases(core.picks(10, 86_400_000).unwrap()), [ReleaseId(2)], "whichever day the rotation starts on");

        // Picked up and playing: still the loaded one.
        core.resume().unwrap();
        assert_eq!(core.loaded_release(), Some(ReleaseId(1)));
        assert_eq!(releases(core.picks(10, 0).unwrap()), [ReleaseId(2)]);

        // Playing the other pick swaps which one is offered.
        core.play_pick(ReleaseId(2), "why".into()).unwrap();
        assert_eq!(releases(core.picks(10, 0).unwrap()), [ReleaseId(1)]);
        core.engine.send(meret_engine::Control::Shutdown);
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
