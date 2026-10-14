//! Which job runs next. Each resource class has its own concurrency limit,
//! and conditions (battery, playback, metered network) can hold a class back.

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};

use crate::JobKind;

#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(tag = "kind", content = "host", rename_all = "snake_case")]
pub enum Resource {
    Io,
    Cpu,
    Net(String),
}

/// What the machine is doing, as far as scheduling cares.
#[derive(Clone, Copy, Debug, Default)]
pub struct Conditions {
    pub on_battery: bool,
    pub metered: bool,
    /// Local playback at a high sample rate: keep CPU headroom for decode.
    pub playing_hi_res: bool,
}

pub struct Scheduler {
    limits: HashMap<Resource, usize>,
    running: HashMap<Resource, usize>,
    /// Ready jobs by (priority desc, sequence).
    ready: BTreeMap<(std::cmp::Reverse<i32>, u64), JobKind>,
    seq: u64,
}

impl Default for Scheduler {
    fn default() -> Self {
        let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
        let mut limits = HashMap::new();
        limits.insert(Resource::Io, 4);
        limits.insert(Resource::Cpu, (cpus / 2).max(1));
        Self { limits, running: HashMap::new(), ready: BTreeMap::new(), seq: 0 }
    }
}

impl Scheduler {
    pub fn push(&mut self, job: JobKind, priority: i32) {
        self.seq += 1;
        self.ready.insert((std::cmp::Reverse(priority), self.seq), job);
    }

    fn limit(&self, r: &Resource, c: Conditions) -> usize {
        match r {
            Resource::Cpu if c.on_battery => 0,
            Resource::Cpu if c.playing_hi_res => 1,
            Resource::Net(_) if c.metered => 0,
            // One request in flight per host; the token bucket paces them.
            Resource::Net(_) => 1,
            r => *self.limits.get(r).unwrap_or(&1),
        }
    }

    /// The highest-priority job whose resource has room, marked running.
    pub fn next(&mut self, c: Conditions) -> Option<JobKind> {
        let key = self
            .ready
            .iter()
            .find(|(_, job)| {
                let r = job.resource();
                *self.running.get(&r).unwrap_or(&0) < self.limit(&r, c)
            })
            .map(|(k, _)| *k)?;
        let job = self.ready.remove(&key)?;
        *self.running.entry(job.resource()).or_default() += 1;
        Some(job)
    }

    pub fn finished(&mut self, job: &JobKind) {
        if let Some(n) = self.running.get_mut(&job.resource()) {
            *n = n.saturating_sub(1);
        }
    }

    pub fn queued(&self) -> usize {
        self.ready.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battery_holds_back_analysis_but_not_scanning() {
        let mut s = Scheduler::default();
        s.push(JobKind::Analyse { recording: 1 }, 0);
        s.push(JobKind::Walk { root: 1 }, -10);
        let c = Conditions { on_battery: true, ..Default::default() };
        assert_eq!(s.next(c), Some(JobKind::Walk { root: 1 }));
        assert_eq!(s.next(c), None);
        assert_eq!(s.next(Conditions::default()), Some(JobKind::Analyse { recording: 1 }));
    }

    #[test]
    fn one_request_in_flight_per_host() {
        let mut s = Scheduler::default();
        s.push(JobKind::Match { source: 1 }, 0);
        s.push(JobKind::Match { source: 2 }, 0);
        let c = Conditions::default();
        let first = s.next(c).unwrap();
        assert_eq!(s.next(c), None);
        s.finished(&first);
        assert_eq!(s.next(c), Some(JobKind::Match { source: 2 }));
    }
}
