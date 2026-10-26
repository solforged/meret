use std::collections::HashSet;

use meret_model::EntityRef;
use meret_query::{Clause, Input, Term, parse};

use crate::{Core, CoreError, MAX_QUEUE, Result, queue_items};

/// What a search stop is called: the Home door that roots it ("All tracks",
/// "Scores"), or the query as typed.
pub fn search_title(query: &str) -> String {
    if query.trim().is_empty() {
        return "All tracks".into();
    }
    match parse(query) {
        Ok(Input::Search(q)) => match q.clauses.as_slice() {
            [Clause { negated: false, term: Term::Idiom { idiom } }] => idiom.plural().into(),
            _ => query.into(),
        },
        _ => query.into(),
    }
}

impl Core {
    /// Plays the active trail: `whole`, every stop of the tree depth first;
    /// otherwise this branch, from the root to the current stop. Releases,
    /// works and games bring their tracks, people and searches none, and a
    /// track plays once however many stops reach it. Each item points back
    /// at its stop. Returns how many tracks were queued.
    pub fn play_trail(&self, whole: bool) -> Result<usize> {
        let now = now_ms();
        let stops: Vec<_> = {
            let history = self.trail.lock();
            let trail = history.current().ok_or_else(|| CoreError::Query("there's no trail to play".into()))?;
            let order = if whole { trail.depth_first() } else { trail.path() };
            order.into_iter().filter(|&i| !trail.is_peek(i, now)).map(|i| (trail.stop(i).entity, trail.stop(i).uid)).collect()
        };
        let why = if whole { "the whole trail" } else { "this branch of the trail" };
        let mut seen = HashSet::new();
        let mut items = vec![];
        for (entity, uid) in stops {
            let rows = match entity {
                EntityRef::Release(id) => self.store.release_page(id)?.map(|p| p.tracks),
                EntityRef::Work(id) => self.store.work_page(id)?.map(|p| p.tracks),
                EntityRef::Game(id) => self.store.game_page(id)?.map(|p| p.tracks),
                _ => None,
            };
            for mut item in queue_items(rows.unwrap_or_default().into_iter().filter(|r| seen.insert(r.track))) {
                item.from_stop = Some(uid);
                item.why = Some(why.into());
                items.push(item);
            }
            if items.len() >= MAX_QUEUE {
                break;
            }
        }
        items.truncate(MAX_QUEUE);
        if items.is_empty() {
            return Err(CoreError::Query("nothing on this trail has tracks to play".into()));
        }
        let queued = items.len();
        self.play(items)?;
        Ok(queued)
    }

    /// Clone before entering the writer: it must never run under the trail lock.
    pub fn save_trails(&self) -> Result<()> {
        let active = self.trail.lock().active_index();
        if let Some(active) = active {
            self.save_trail_at(active)?;
        }
        Ok(())
    }

    /// A search can move an older tree to the end of history, so persist all
    /// positions then. Ordinary stop mutations only write the active tree.
    pub fn save_trail_history(&self) -> Result<()> {
        let entries = {
            let history = self.trail.lock();
            let active = history.active_index();
            history.entries().enumerate().map(|(position, (trail, departure))| {
                let trail = if Some(position) == active { trail.snapshot(now_ms()) } else { trail.clone() };
                (trail, position, departure)
            }).collect::<Vec<_>>()
        };
        for (trail, position, departure) in entries {
            self.store.save_trail_snapshot(trail, position, departure)?;
        }
        Ok(())
    }

    /// Cross-trail navigation also checkpoints the tree just left, whose dwell
    /// interval ended in the graph before its replacement became active.
    pub fn save_trail_at(&self, position: usize) -> Result<()> {
        let entry = {
            let history = self.trail.lock();
            history.entries().nth(position).map(|(trail, departure)| {
                let trail = if history.active_index() == Some(position) { trail.snapshot(now_ms()) } else { trail.clone() };
                (trail, departure)
            })
        };
        if let Some((trail, departure)) = entry {
            self.store.save_trail_snapshot(trail, position, departure)?;
        }
        Ok(())
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};
    use meret_graph::{Action, Trail, Via};
    use meret_model::{AgentId, EntityRef, ReleaseId, ThreadKind};

    #[test]
    fn searches_a_door_roots_take_the_doors_name() {
        assert_eq!(search_title(""), "All tracks");
        assert_eq!(search_title("idiom:score"), "Scores");
        assert_eq!(search_title("idiom:session"), "Sessions");
        assert_eq!(search_title("idiom:score year:2001"), "idiom:score year:2001");
        assert_eq!(search_title("-idiom:score"), "-idiom:score");
        assert_eq!(search_title("lepreezy"), "lepreezy");
    }

    #[test]
    fn walking_then_reopening_starts_on_front_and_back_restores_same_tree() {
        let dir = std::env::temp_dir().join(format!("meret-core-trail-{}-{}", std::process::id(), now_ms()));
        let config = CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() };
        let (scans, _) = crossbeam_channel::unbounded();
        let core = Core::new(config.clone(), scans).unwrap();
        {
            let mut history = core.trail.lock();
            history.start(Trail::start(EntityRef::Search, Some("test".into()), now_ms()), now_ms());
        }
        core.save_trail_history().unwrap();
        {
            let mut history = core.trail.lock();
            let trail = history.current_mut().unwrap();
            let release = trail.follow(0, EntityRef::Release(ReleaseId(1)), Via { kind: ThreadKind::Matched, source: "library".into() }, now_ms());
            trail.act(release, Action::Played);
            trail.follow(release, EntityRef::Agent(AgentId(2)), Via { kind: ThreadKind::By, source: "local_tags".into() }, now_ms());
        }
        core.save_trails().unwrap();
        let expected = core.store.load_trails().unwrap()[0].0.stops().to_vec();
        drop(core);
        let (scans, _) = crossbeam_channel::unbounded();
        let core = Core::new(config, scans).unwrap();
        assert!(core.trail.lock().current().is_none());
        assert!(!core.trail.lock().forward(now_ms()));
        assert!(core.trail.lock().back(now_ms()));
        {
            let history = core.trail.lock();
            let trail = history.current().unwrap();
            assert_eq!(trail.current(), 2);
            assert_eq!(trail.root_query.as_deref(), Some("test"));
            assert_eq!(trail.stops(), expected);
        }
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn playing_a_branch_or_the_tree_queues_each_release_once() {
        let dir = std::env::temp_dir().join(format!("meret-core-play-trail-{}-{}", std::process::id(), now_ms()));
        std::fs::create_dir_all(dir.join("music")).unwrap();
        std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac"), dir.join("music/tone.flac")).unwrap();
        let (scans, _) = crossbeam_channel::unbounded();
        let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() }, scans).unwrap();
        let root = meret_library::add_root(&core.store, &dir.join("music")).unwrap();
        meret_library::scan(&core.store, root, &|_| {}).unwrap();
        let release = core.store.track_rows(&core.store.load_columns().unwrap().track).unwrap()[0].release;
        core.store.writer.write(|tx| tx.execute("INSERT INTO agent (id, kind, name, rev) VALUES (900, 0, 'Fixture Person', 1)", [])).unwrap();
        let t0 = now_ms() - 600_000;
        let via = |kind| Via { kind, source: "local_tags".into() };
        let mut trail = Trail::start(EntityRef::Search, Some("tone".into()), t0);
        // The release reached twice, on two branches: a meeting.
        trail.follow(0, EntityRef::Release(release), via(ThreadKind::Matched), t0 + 60_000);
        trail.back(t0 + 120_000);
        let person = trail.follow(0, EntityRef::Agent(AgentId(900)), via(ThreadKind::Matched), t0 + 180_000);
        trail.follow(person, EntityRef::Release(release), via(ThreadKind::By), t0 + 240_000);
        trail.back(t0 + 300_000);
        core.trail.lock().start(trail, t0);
        assert!(core.play_trail(false).is_err(), "a search and a person have no tracks of their own");
        assert_eq!(core.play_trail(true).unwrap(), 1);
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
