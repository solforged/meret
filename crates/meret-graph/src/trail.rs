//! Trails are trees (decided 2026-10-13; plates 06–08).
//!
//! * Following a thread from any stop except the last starts a branch.
//!   Nothing is thrown away.
//! * Panes show one branch: the path from the root to the current stop.
//! * A stop left within a few seconds, with nothing done on it, is a peek
//!   and folds away.
//! * Two branches that reach the same thing meet.
//! * A branch with something done on it (played, wanted, crated, noted) is
//!   always kept; one without can be pruned.
//!
//! Stops are append-only, which is what lets trails merge across devices.
//! Pruning hides; it never deletes.

use meret_model::{EntityRef, StopUid, ThreadKind, TrailUid};
use serde::{Deserialize, Serialize};

/// A stop left sooner than this, with nothing done on it, is a peek.
pub const PEEK_MS: i64 = 8_000;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Via {
    pub kind: ThreadKind,
    pub source: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    Played,
    Wanted,
    Crated,
    Noted,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Stop {
    pub uid: StopUid,
    pub parent: Option<usize>,
    pub entity: EntityRef,
    pub via: Option<Via>,
    pub opened_at: i64,
    pub dwell_ms: i64,
    pub actions: Vec<Action>,
    pub pruned: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Branch {
    /// Stop indices from the stop after the fork to the leaf.
    pub stops: Vec<usize>,
    /// Where it leaves the trunk it grew from.
    pub fork: Option<usize>,
    pub leaf: usize,
    pub has_actions: bool,
}

#[derive(Debug, PartialEq, thiserror::Error)]
pub enum PruneError {
    #[error("this branch has things done on it, so it's kept with the trail")]
    HasActions,
    #[error("that stop is on the current branch")]
    Current,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Trail {
    pub uid: TrailUid,
    pub name: Option<String>,
    /// The search that started this tree, if one did.
    pub root_query: Option<String>,
    pub kept: bool,
    stops: Vec<Stop>,
    current: usize,
    /// When the current stop was entered, to measure dwell.
    entered_at: i64,
}

impl Trail {
    pub fn start(entity: EntityRef, root_query: Option<String>, now: i64) -> Self {
        let root = Stop {
            uid: StopUid::new(),
            parent: None,
            entity,
            via: None,
            opened_at: now,
            dwell_ms: 0,
            actions: vec![],
            pruned: false,
        };
        Self { uid: TrailUid::new(), name: None, root_query, kept: false, stops: vec![root], current: 0, entered_at: now }
    }

    pub fn stop(&self, i: usize) -> &Stop {
        &self.stops[i]
    }

    pub fn len(&self) -> usize {
        self.stops.len()
    }

    pub fn is_empty(&self) -> bool {
        self.stops.is_empty()
    }

    pub fn current(&self) -> usize {
        self.current
    }

    fn children(&self, i: usize) -> impl Iterator<Item = usize> + '_ {
        self.stops.iter().enumerate().filter(move |(_, s)| s.parent == Some(i) && !s.pruned).map(|(j, _)| j)
    }

    fn leave_current(&mut self, now: i64) {
        self.stops[self.current].dwell_ms += now - self.entered_at;
        self.entered_at = now;
    }

    fn enter(&mut self, i: usize, now: i64) {
        self.leave_current(now);
        self.current = i;
    }

    /// Follows a thread from stop `from` (usually a visible pane). If `from`
    /// already leads somewhere, this starts a branch.
    pub fn follow(&mut self, from: usize, entity: EntityRef, via: Via, now: i64) -> usize {
        // Following the same thread to the same place again revisits it.
        let existing = self.children(from).find(|&c| self.stops[c].entity == entity);
        if let Some(existing) = existing {
            self.enter(existing, now);
            return existing;
        }
        self.stops.push(Stop {
            uid: StopUid::new(),
            parent: Some(from),
            entity,
            via: Some(via),
            opened_at: now,
            dwell_ms: 0,
            actions: vec![],
            pruned: false,
        });
        let i = self.stops.len() - 1;
        self.enter(i, now);
        i
    }

    /// Something done in stop `stop`'s pane, which keeps its branch. False
    /// for a stop that doesn't exist.
    pub fn act(&mut self, stop: usize, action: Action) -> bool {
        let Some(s) = self.stops.get_mut(stop) else { return false };
        s.actions.push(action);
        true
    }

    /// The panes: root to the current stop.
    pub fn path(&self) -> Vec<usize> {
        let mut out = vec![self.current];
        let mut i = self.current;
        while let Some(p) = self.stops[i].parent {
            out.push(p);
            i = p;
        }
        out.reverse();
        out
    }

    /// `[`: one stop back along this branch.
    pub fn back(&mut self, now: i64) -> bool {
        match self.stops[self.current].parent {
            Some(p) => {
                self.enter(p, now);
                true
            }
            None => false,
        }
    }

    /// `]`: forward to the most recently opened child.
    pub fn forward(&mut self, now: i64) -> bool {
        match self.children(self.current).max_by_key(|&c| self.stops[c].opened_at) {
            Some(c) => {
                self.enter(c, now);
                true
            }
            None => false,
        }
    }

    /// Clicking a star: stop `i` becomes current, and the panes become its
    /// path. False for a stop that doesn't exist or was pruned.
    pub fn go(&mut self, i: usize, now: i64) -> bool {
        if self.stops.get(i).is_none_or(|s| s.pruned) {
            return false;
        }
        self.enter(i, now);
        true
    }

    pub fn is_peek(&self, i: usize, now: i64) -> bool {
        let s = &self.stops[i];
        let dwell = if i == self.current { s.dwell_ms + now - self.entered_at } else { s.dwell_ms };
        i != self.current && s.actions.is_empty() && dwell < PEEK_MS && self.children(i).next().is_none()
    }

    /// Stops with more than one branch leaving them, peeks not counted.
    pub fn forks(&self, now: i64) -> Vec<usize> {
        (0..self.stops.len())
            .filter(|&i| !self.stops[i].pruned && self.children(i).filter(|&c| !self.is_peek(c, now)).count() > 1)
            .collect()
    }

    /// Every branch, peeks folded away. The first is the one containing the
    /// current stop.
    pub fn branches(&self, now: i64) -> Vec<Branch> {
        let leaves: Vec<usize> = (0..self.stops.len())
            .filter(|&i| !self.stops[i].pruned && self.children(i).next().is_none() && !self.is_peek(i, now))
            .collect();
        let forks = self.forks(now);
        let on_path = self.path();
        let mut out: Vec<Branch> = leaves
            .into_iter()
            .map(|leaf| {
                let mut stops = vec![leaf];
                let mut i = leaf;
                let mut fork = None;
                while let Some(p) = self.stops[i].parent {
                    if forks.contains(&p) {
                        fork = Some(p);
                        break;
                    }
                    stops.push(p);
                    i = p;
                }
                stops.reverse();
                let has_actions = stops.iter().any(|&s| !self.stops[s].actions.is_empty());
                Branch { stops, fork, leaf, has_actions }
            })
            .collect();
        out.sort_by_key(|b| (!b.stops.iter().any(|s| on_path.contains(s)), std::cmp::Reverse(self.stops[b.leaf].opened_at)));
        out
    }

    /// Pairs of stops on different branches that reached the same thing.
    pub fn meetings(&self) -> Vec<(usize, usize)> {
        let mut out = vec![];
        for i in 0..self.stops.len() {
            for j in (i + 1)..self.stops.len() {
                let (a, b) = (&self.stops[i], &self.stops[j]);
                if !a.pruned && !b.pruned && a.entity == b.entity && !self.is_ancestor(i, j) {
                    out.push((i, j));
                }
            }
        }
        out
    }

    fn is_ancestor(&self, a: usize, mut b: usize) -> bool {
        while let Some(p) = self.stops[b].parent {
            if p == a {
                return true;
            }
            b = p;
        }
        false
    }

    /// `⌘⌫`: hides a branch that has nothing on it.
    pub fn prune(&mut self, branch: &Branch) -> Result<(), PruneError> {
        if branch.has_actions {
            return Err(PruneError::HasActions);
        }
        if branch.stops.contains(&self.current) {
            return Err(PruneError::Current);
        }
        for &s in &branch.stops {
            self.stops[s].pruned = true;
        }
        Ok(())
    }

    /// "Play the whole tree, depth first": stops in visiting order.
    pub fn depth_first(&self) -> Vec<usize> {
        let mut out = vec![];
        let mut stack = vec![0usize];
        while let Some(i) = stack.pop() {
            out.push(i);
            let mut kids: Vec<usize> = self.children(i).collect();
            kids.sort_by_key(|&c| std::cmp::Reverse(self.stops[c].opened_at));
            stack.extend(kids);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use meret_model::{AgentId, RecordingId, ReleaseId};

    fn via(kind: ThreadKind) -> Via {
        Via { kind, source: "musicbrainz".into() }
    }

    const MIN: i64 = 60_000;

    /// Plate 06/07: Corridors of Time → Mitsuda → Xenogears, then three branches.
    fn tuesday() -> (Trail, [usize; 9]) {
        let mut t = Trail::start(EntityRef::Recording(RecordingId(1)), None, 0);
        let mitsuda = t.follow(0, EntityRef::Agent(AgentId(10)), via(ThreadKind::ComposedBy), MIN);
        let xeno = t.follow(mitsuda, EntityRef::Release(ReleaseId(20)), via(ThreadKind::Scored), 2 * MIN);
        t.act(xeno, Action::Played);
        let hogg = t.follow(xeno, EntityRef::Agent(AgentId(11)), via(ThreadKind::SungBy), 9 * MIN);
        let iona = t.follow(hogg, EntityRef::Agent(AgentId(12)), via(ThreadKind::MemberOf), 13 * MIN);
        t.act(iona, Action::Wanted);
        let open_sky = t.follow(iona, EntityRef::Release(ReleaseId(30)), via(ThreadKind::PerformedBy), 14 * MIN);
        t.back(14 * MIN + 6_000); // a 6-second peek
        let troy = t.follow(iona, EntityRef::Agent(AgentId(13)), via(ThreadKind::MemberOf), 18 * MIN);
        let uematsu = t.follow(mitsuda, EntityRef::Agent(AgentId(14)), via(ThreadKind::WorkedWith), 21 * MIN);
        let creid = t.follow(xeno, EntityRef::Release(ReleaseId(21)), via(ThreadKind::ArrangedAs), 34 * MIN);
        (t, [mitsuda, xeno, hogg, iona, open_sky, troy, uematsu, creid, 0])
    }

    #[test]
    fn following_from_an_earlier_stop_forks() {
        let (t, [mitsuda, xeno, ..]) = tuesday();
        assert_eq!(t.forks(40 * MIN), vec![mitsuda, xeno]);
    }

    #[test]
    fn panes_show_root_to_current() {
        let (t, [mitsuda, xeno, .., creid, _]) = tuesday();
        assert_eq!(t.path(), vec![0, mitsuda, xeno, creid]);
    }

    #[test]
    fn a_star_click_switches_branch_and_brackets_walk_it() {
        let (mut t, [mitsuda, xeno, hogg, iona, _, troy, ..]) = tuesday();
        assert!(t.go(troy, 40 * MIN));
        assert_eq!(t.path(), vec![0, mitsuda, xeno, hogg, iona, troy]);
        assert!(t.back(41 * MIN));
        assert_eq!(t.current(), iona);
        // `]` returns to the newest child, not the peek opened before it.
        assert!(t.forward(42 * MIN));
        assert_eq!(t.current(), troy);
        assert!(!t.go(99, 43 * MIN));
        assert_eq!(t.current(), troy);
    }

    #[test]
    fn peeks_fold_away_and_branches_list_current_first() {
        let (t, [_, _, hogg, iona, open_sky, troy, uematsu, creid, _]) = tuesday();
        let now = 40 * MIN;
        assert!(t.is_peek(open_sky, now));
        let b = t.branches(now);
        assert_eq!(b.len(), 3);
        assert_eq!(b[0].leaf, creid);
        let iona_branch = b.iter().find(|b| b.leaf == troy).unwrap();
        assert_eq!(iona_branch.stops, vec![hogg, iona, troy]);
        assert!(iona_branch.has_actions);
        assert!(b.iter().any(|b| b.leaf == uematsu && !b.has_actions));
    }

    #[test]
    fn branches_with_actions_are_kept() {
        let (mut t, [.., troy, uematsu, _, _]) = tuesday();
        let b = t.branches(40 * MIN);
        let iona = b.iter().find(|b| b.leaf == troy).unwrap().clone();
        assert_eq!(t.prune(&iona), Err(PruneError::HasActions));
        let ff6 = b.iter().find(|b| b.leaf == uematsu).unwrap().clone();
        assert_eq!(t.prune(&ff6), Ok(()));
        assert_eq!(t.branches(40 * MIN).len(), 2);
    }

    #[test]
    fn two_routes_to_one_place_meet() {
        let (mut t, [.., creid, _]) = tuesday();
        let iona_again = t.follow(creid, EntityRef::Agent(AgentId(12)), via(ThreadKind::SoundsLike), 38 * MIN);
        assert_eq!(t.meetings(), vec![(4, iona_again)]);
    }

    #[test]
    fn back_and_forward_walk_one_branch() {
        let (mut t, [_, xeno, .., creid, _]) = tuesday();
        assert!(t.back(41 * MIN));
        assert_eq!(t.current(), xeno);
        assert!(t.forward(42 * MIN));
        assert_eq!(t.current(), creid, "forward picks the most recent branch");
    }

    #[test]
    fn depth_first_visits_every_stop_once() {
        let (t, _) = tuesday();
        let order = t.depth_first();
        assert_eq!(order.len(), t.len());
        assert_eq!(order[0], 0);
    }
}
