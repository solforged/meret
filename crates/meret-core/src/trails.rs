use crate::{Core, Result};

impl Core {
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
}
