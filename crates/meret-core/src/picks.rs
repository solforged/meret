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
    /// Up to `limit` picks, best first, never the same release twice.
    pub fn picks(&self, limit: usize, now_ms: i64) -> Result<Vec<Pick>> {
        let mut picks: Vec<Pick> = Vec::with_capacity(limit);
        let push = |picks: &mut Vec<Pick>, release: ReleaseId, why: Why| {
            if picks.len() < limit && !picks.iter().any(|p| p.release == release) {
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
                (None, Some((EntityRef::Search, query))) => query.filter(|q| !q.is_empty()).unwrap_or_else(|| "Everything".into()),
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
