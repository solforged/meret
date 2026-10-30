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

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
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

    /// Rebuilds persisted stops in their original insertion order. Restoring
    /// starts a new dwell interval; time with the app closed is not dwell.
    pub fn restore(
        uid: TrailUid, name: Option<String>, root_query: Option<String>, kept: bool,
        stops: Vec<Stop>, current: usize, now: i64,
    ) -> Self {
        assert!(!stops.is_empty() && current < stops.len(), "a trail needs a current stop");
        Self { uid, name, root_query, kept, stops, current, entered_at: now }
    }

    pub fn stops(&self) -> &[Stop] {
        &self.stops
    }

    /// A storage snapshot includes dwell up to this instant, without changing
    /// the live interval (and therefore without counting it twice).
    pub fn snapshot(&self, now: i64) -> Self {
        let mut trail = self.clone();
        trail.leave_current(now);
        trail
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

    /// When you last moved in this trail: the stop you're on was entered
    /// then. Every list of trails shows this time and orders by it.
    pub fn last_visited(&self) -> i64 {
        self.stops[self.current].opened_at
    }

    /// The stops that count: not pruned, and not a folded peek. One
    /// definition for the chip, the tree and every list, in the order they
    /// were first opened.
    pub fn visible(&self, now: i64) -> Vec<usize> {
        (0..self.stops.len()).filter(|&i| !self.stops[i].pruned && !self.is_peek(i, now)).collect()
    }

    /// Whether `other`, a trail just rooted, only repeats this one: a trail
    /// that nothing was done on, with nothing on it but the same root.
    fn is_bare_visit(&self, other: &Trail, now: i64) -> bool {
        !self.kept
            && self.name.is_none()
            && self.root_query == other.root_query
            && self.stops[0].entity == other.stops[0].entity
            && self.stops[0].actions.is_empty()
            && self.current == 0
            && (1..self.stops.len()).all(|i| self.stops[i].pruned || self.is_peek(i, now))
    }

    /// Returns to stop `i` as the open stop, starting a new dwell interval.
    fn resume_at(&mut self, i: usize, now: i64) {
        self.current = i;
        self.entered_at = now;
        self.stops[i].opened_at = now;
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
        self.stops[i].opened_at = now;
    }

    /// Follows a thread from stop `from` (usually a visible pane). If `from`
    /// already leads somewhere, this starts a branch.
    pub fn follow(&mut self, from: usize, entity: EntityRef, via: Via, now: i64) -> usize {
        // A thread back onto this branch revisits its stop, not a duplicate.
        let mut ancestor = Some(self.current);
        while let Some(i) = ancestor {
            if self.stops[i].entity == entity {
                self.enter(i, now);
                return i;
            }
            ancestor = self.stops[i].parent;
        }
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

    /// `]`: forward to the most recently entered child, excluding folded peeks.
    pub fn forward(&mut self, now: i64) -> bool {
        match self.forward_child(self.current, now) {
            Some(c) => {
                self.enter(c, now);
                true
            }
            None => false,
        }
    }

    /// Clicking a star or a branch row: stop `i` becomes current, and the
    /// panes become its path. A folded peek can be re-entered this way; it
    /// stops being a peek while you're on it. False for a stop that doesn't
    /// exist or was pruned.
    pub fn go(&mut self, i: usize, now: i64) -> bool {
        if self.stops.get(i).is_none_or(|s| s.pruned) {
            return false;
        }
        self.enter(i, now);
        true
    }

    /// `⌥]` (`step` 1) and `⌥[` (`step` -1): the next or previous branch at
    /// the nearest fork at or above the current stop, in the order they were
    /// started, wrapping round. It lands where you last were on that branch.
    /// At the fork itself, the branch you're on is the one `]` would walk
    /// into. False with no fork there.
    pub fn sibling(&mut self, step: isize, now: i64) -> bool {
        let forks = self.forks(now);
        let path = self.path();
        let Some(at) = path.iter().rposition(|s| forks.contains(s)) else { return false };
        let fork = path[at];
        let Some(on) = path.get(at + 1).copied().or_else(|| self.forward_child(fork, now)) else { return false };
        let kids: Vec<usize> = self.children(fork).filter(|&c| !self.is_peek(c, now)).collect();
        let Some(here) = kids.iter().position(|&c| c == on) else { return false };
        let next = kids[(here as isize + step).rem_euclid(kids.len() as isize) as usize];
        let last = (next..self.stops.len())
            .filter(|&s| !self.stops[s].pruned && (s == next || self.is_ancestor(next, s)) && !self.is_peek(s, now))
            .max_by_key(|&s| self.stops[s].opened_at)
            .unwrap_or(next);
        self.enter(last, now);
        true
    }

    /// The child `]` walks into: the most recently entered, peeks excluded.
    fn forward_child(&self, i: usize, now: i64) -> Option<usize> {
        self.children(i).filter(|&c| !self.is_peek(c, now)).max_by_key(|&c| self.stops[c].opened_at)
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

/// Persistent trail history, oldest first. The trail you started, returned
/// to or opened last is at the end, so history order is the order you last
/// visited them in, and while a trail is open it is the last one. Navigation
/// never discards a tree, and `[` `]` never leave the open one.
#[derive(Default)]
pub struct TrailHistory {
    trails: Vec<Trail>,
    active: Option<usize>,
}

impl TrailHistory {
    /// Reopens on Today. `[` enters the newest trail where it was left.
    pub fn restore(trails: Vec<Trail>) -> Self {
        Self { trails, active: None }
    }

    pub fn active_index(&self) -> Option<usize> {
        self.active
    }

    pub fn entries(&self) -> impl DoubleEndedIterator<Item = &Trail> {
        self.trails.iter()
    }

    pub fn current(&self) -> Option<&Trail> {
        self.active.map(|i| &self.trails[i])
    }

    pub fn current_mut(&mut self) -> Option<&mut Trail> {
        self.active.map(|i| &mut self.trails[i])
    }

    /// Ends the open trail's stay on its current stop.
    fn leave(&mut self, now: i64) {
        if let Some(i) = self.active {
            self.trails[i].leave_current(now);
        }
    }

    /// Roots `trail` as the newest. A door visit (a Home door, `⌘L`, an item
    /// opened from Today, a search) that only repeats a trail with nothing
    /// but that root on it brings the existing trail back instead, so
    /// history doesn't fill with copies.
    pub fn start(&mut self, trail: Trail, now: i64) -> &Trail {
        self.leave(now);
        match self.trails.iter().rposition(|old| old.is_bare_visit(&trail, now)) {
            Some(i) => {
                let mut old = self.trails.remove(i);
                old.resume_at(0, now);
                self.trails.push(old);
            }
            None => self.trails.push(trail),
        }
        self.active = Some(self.trails.len() - 1);
        self.current().expect("the trail just started")
    }

    /// `[`: one stop back along the open trail, and never out of it: at its
    /// first stop this is false. With no trail open, it enters the newest one
    /// where it was left.
    pub fn back(&mut self, now: i64) -> bool {
        match self.active {
            Some(i) => self.trails[i].back(now),
            None => {
                let Some(i) = self.trails.len().checked_sub(1) else { return false };
                self.active = Some(i);
                self.trails[i].entered_at = now;
                true
            }
        }
    }

    /// `]`: walks to the newest visible child, including into a dimmed pane
    /// ahead, and never into another trail.
    pub fn forward(&mut self, now: i64) -> bool {
        match self.active {
            Some(i) => self.trails[i].forward(now),
            None => false,
        }
    }

    /// A trail picked from Home's lists or the tree: it becomes the newest,
    /// open at the stop it was left on.
    pub fn open(&mut self, uid: &TrailUid, now: i64) -> bool {
        let Some(i) = self.trails.iter().position(|trail| trail.uid == *uid) else { return false };
        self.leave(now);
        let mut trail = self.trails.remove(i);
        let at = trail.current;
        trail.resume_at(at, now);
        self.trails.push(trail);
        self.active = Some(self.trails.len() - 1);
        true
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
    fn alt_brackets_switch_branch_at_the_nearest_fork_and_land_where_you_were() {
        let (mut t, [mitsuda, xeno, _, _, _, troy, uematsu, creid, _]) = tuesday();
        // From Creid, the nearest fork above is Xenogears: Hogg's branch, last left at Troy.
        assert!(t.sibling(1, 40 * MIN));
        assert_eq!(t.current(), troy);
        // Two branches there, so either direction swaps back.
        assert!(t.sibling(-1, 41 * MIN));
        assert_eq!(t.current(), creid);
        // At Uematsu the nearest fork is Mitsuda; its other branch was last on Creid.
        assert!(t.go(uematsu, 42 * MIN));
        assert!(t.sibling(1, 43 * MIN));
        assert_eq!(t.current(), creid);
        assert_eq!(t.path(), vec![0, mitsuda, xeno, creid]);
        let mut single = Trail::start(EntityRef::Recording(RecordingId(1)), None, 0);
        single.follow(0, EntityRef::Agent(AgentId(10)), via(ThreadKind::ComposedBy), MIN);
        assert!(!single.sibling(1, 2 * MIN), "no fork, no sibling");
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
    fn following_back_to_an_ancestor_or_current_reuses_the_stop() {
        let mut t = Trail::start(EntityRef::Release(ReleaseId(1)), None, 0);
        let person = t.follow(0, EntityRef::Agent(AgentId(2)), via(ThreadKind::AlbumArtist), MIN);
        assert_eq!(t.follow(person, EntityRef::Release(ReleaseId(1)), via(ThreadKind::AppearsOn), 2 * MIN), 0);
        assert_eq!(t.len(), 2);
        assert_eq!(t.path(), vec![0]);
        assert_eq!(t.follow(0, EntityRef::Release(ReleaseId(1)), via(ThreadKind::AppearsOn), 3 * MIN), 0);
        assert_eq!(t.len(), 2);
        assert_eq!(t.stop(0).opened_at, 3 * MIN);
    }

    #[test]
    fn reentering_a_child_refreshes_which_branch_forward_chooses() {
        let mut t = Trail::start(EntityRef::Release(ReleaseId(1)), None, 0);
        let first = t.follow(0, EntityRef::Agent(AgentId(2)), via(ThreadKind::By), MIN);
        let second = t.follow(0, EntityRef::Agent(AgentId(3)), via(ThreadKind::By), 2 * MIN);
        t.act(first, Action::Played);
        t.act(second, Action::Played);
        assert_eq!(t.follow(0, EntityRef::Agent(AgentId(2)), via(ThreadKind::By), 3 * MIN), first);
        assert_eq!(t.stop(first).opened_at, 3 * MIN);
        assert!(t.back(4 * MIN));
        assert!(t.forward(5 * MIN));
        assert_eq!(t.current(), first);
        assert_eq!(t.len(), 3);
    }

    #[test]
    fn forward_skips_folded_peeks_but_a_list_can_reenter_one() {
        let mut t = Trail::start(EntityRef::Release(ReleaseId(1)), None, 0);
        let kept = t.follow(0, EntityRef::Agent(AgentId(2)), via(ThreadKind::By), MIN);
        t.back(2 * MIN);
        let peek = t.follow(0, EntityRef::Agent(AgentId(3)), via(ThreadKind::By), 3 * MIN);
        t.back(3 * MIN + 1);
        assert!(t.is_peek(peek, 4 * MIN));
        assert_eq!(t.visible(4 * MIN), vec![0, kept], "a folded peek isn't a stop that counts");
        assert!(t.forward(4 * MIN));
        assert_eq!(t.current(), kept);
        t.back(5 * MIN);
        assert!(t.go(peek, 5 * MIN + 1), "the branch row for a peek takes you back to it");
        assert_eq!(t.current(), peek);
        assert!(!t.is_peek(peek, 5 * MIN + 2), "the stop you're on isn't folded");
        t.back(6 * MIN);
        t.stops[kept].pruned = true;
        t.stops[peek].pruned = true;
        assert!(!t.forward(7 * MIN));
        assert!(!t.go(peek, 7 * MIN), "a pruned stop stays hidden");
    }

    #[test]
    fn back_never_leaves_the_trail_and_stops_at_its_first_stop() {
        let mut history = TrailHistory::default();
        assert!(!history.back(0));
        assert!(!history.forward(0));
        history.start(Trail::start(EntityRef::Release(ReleaseId(1)), None, 0), 0);
        let person = history.current_mut().unwrap().follow(0, EntityRef::Agent(AgentId(2)), via(ThreadKind::By), MIN);
        history.start(Trail::start(EntityRef::Release(ReleaseId(3)), None, 2 * MIN), 2 * MIN);
        // The first stop of the newest trail: nothing earlier on it, so `[` does nothing.
        assert!(!history.back(3 * MIN));
        assert_eq!(history.active_index(), Some(1));
        assert_eq!(history.current().unwrap().stop(0).entity, EntityRef::Release(ReleaseId(3)));
        assert_eq!(history.current().unwrap().current(), 0);
        // The older trail is reached by opening it, where it was left, and keeps its own time.
        let older = history.entries().next().unwrap().uid;
        assert!(history.open(&older, 4 * MIN));
        assert_eq!(history.current().unwrap().current(), person);
        assert_eq!(history.current().unwrap().stop(person).dwell_ms, MIN, "time in another trail isn't dwell");
        assert!(history.back(5 * MIN));
        assert!(!history.back(6 * MIN), "the root of an older trail is still the end of it");
        assert_eq!(history.current().unwrap().stop(0).entity, EntityRef::Release(ReleaseId(1)));
    }

    #[test]
    fn forward_goes_into_the_dimmed_pane_ahead_and_never_into_another_trail() {
        let mut history = TrailHistory::default();
        history.start(Trail::start(EntityRef::Release(ReleaseId(1)), None, 0), 0);
        let person = history.current_mut().unwrap().follow(0, EntityRef::Agent(AgentId(2)), via(ThreadKind::By), MIN);
        history.start(Trail::start(EntityRef::Release(ReleaseId(3)), None, 2 * MIN), 2 * MIN);
        let older = history.entries().next().unwrap().uid;
        assert!(history.open(&older, 3 * MIN));
        assert!(history.back(4 * MIN));
        assert_eq!(history.current().unwrap().current(), 0);
        assert!(history.forward(5 * MIN), "the pane ahead, dimmed, is the next stop");
        assert_eq!(history.current().unwrap().current(), person);
        assert!(!history.forward(6 * MIN), "the end of this trail is the end of `]`");
        assert_eq!(history.current().unwrap().uid, older);
    }

    #[test]
    fn opening_a_trail_makes_it_the_newest_and_its_last_visit_the_time_to_show() {
        let mut history = TrailHistory::default();
        for id in 1..=3 {
            history.start(Trail::start(EntityRef::Release(ReleaseId(id)), None, id * MIN), id * MIN);
        }
        let first = history.entries().next().unwrap().uid;
        assert!(history.open(&first, 10 * MIN));
        assert_eq!(history.active_index(), Some(2));
        let times: Vec<i64> = history.entries().map(Trail::last_visited).collect();
        assert_eq!(times, vec![2 * MIN, 3 * MIN, 10 * MIN], "history order is last-visited order");
        assert_eq!(history.entries().map(|t| t.stop(0).entity).next_back(), Some(EntityRef::Release(ReleaseId(1))));
        assert!(!history.open(&TrailUid::new(), 11 * MIN));
    }

    #[test]
    fn a_door_visit_reuses_a_trail_that_only_has_that_root_and_moves_it_to_the_top() {
        let door = |query: &str, at: i64| Trail::start(EntityRef::Search, Some(query.into()), at);
        let mut history = TrailHistory::default();
        history.start(door("idiom:score", 0), 0);
        let scores = history.current().unwrap().uid;
        history.start(door("", MIN), MIN);
        let tracks = history.current().unwrap().uid;
        history.start(door("idiom:score", 2 * MIN), 2 * MIN);
        assert_eq!(history.entries().count(), 2, "Scores again is the same trail, not a copy");
        assert_eq!(history.current().unwrap().uid, scores);
        assert_eq!(history.active_index(), Some(1));
        assert_eq!(history.entries().next().unwrap().uid, tracks);
        assert_eq!(history.current().unwrap().last_visited(), 2 * MIN);
        // A peek on it, left within the peek window, is still a bare visit.
        let trail = history.current_mut().unwrap();
        let peek = trail.follow(0, EntityRef::Release(ReleaseId(1)), via(ThreadKind::Matched), 3 * MIN);
        trail.back(3 * MIN + 1);
        history.start(door("", 4 * MIN), 4 * MIN);
        history.start(door("idiom:score", 5 * MIN), 5 * MIN);
        assert_eq!(history.entries().count(), 2);
        assert!(history.current().unwrap().is_peek(peek, 5 * MIN));
        // Anything done there, a followed stop, a name or a keep makes it a trail of its own.
        let trail = history.current_mut().unwrap();
        trail.follow(0, EntityRef::Release(ReleaseId(2)), via(ThreadKind::Matched), 6 * MIN);
        trail.back(7 * MIN);
        history.start(door("idiom:score", 8 * MIN), 8 * MIN);
        assert_eq!(history.entries().count(), 3);
        history.current_mut().unwrap().act(0, Action::Played);
        history.start(door("idiom:score", 9 * MIN), 9 * MIN);
        assert_eq!(history.entries().count(), 4);
        history.current_mut().unwrap().kept = true;
        history.start(door("idiom:score", 10 * MIN), 10 * MIN);
        assert_eq!(history.entries().count(), 5);
        history.current_mut().unwrap().name = Some("Scores I like".into());
        history.current_mut().unwrap().kept = false;
        history.start(door("idiom:score", 11 * MIN), 11 * MIN);
        assert_eq!(history.entries().count(), 6);
    }

    #[test]
    fn a_reused_door_trail_doesnt_count_time_away_as_dwell() {
        let mut history = TrailHistory::default();
        history.start(Trail::start(EntityRef::Search, Some("a".into()), 0), 0);
        history.start(Trail::start(EntityRef::Search, Some("b".into()), MIN), MIN);
        history.start(Trail::start(EntityRef::Search, Some("a".into()), 10 * MIN), 10 * MIN);
        assert_eq!(history.current().unwrap().snapshot(11 * MIN).stop(0).dwell_ms, MIN + MIN);
    }

    #[test]
    fn alt_brackets_at_the_fork_itself_swap_to_the_other_branch() {
        let (mut t, [mitsuda, xeno, _, _, _, troy, uematsu, ..]) = tuesday();
        // Xenogears forks into Hogg's branch (last left at Troy) and Creid's,
        // which is the one ahead of it, so either way round is Hogg's.
        assert!(t.go(xeno, 40 * MIN));
        assert!(t.sibling(1, 41 * MIN));
        assert_eq!(t.current(), troy);
        assert!(t.go(xeno, 42 * MIN));
        assert!(t.sibling(-1, 43 * MIN));
        assert_eq!(t.current(), troy);
        // At Mitsuda, Xenogears' branch is ahead, so the other is Uematsu's.
        assert!(t.go(mitsuda, 44 * MIN));
        assert!(t.sibling(1, 45 * MIN));
        assert_eq!(t.current(), uematsu);
        // And with Uematsu ahead now, the swap goes back to where Xenogears' branch was last.
        assert!(t.go(mitsuda, 46 * MIN));
        assert!(t.sibling(1, 47 * MIN));
        assert_eq!(t.current(), troy);
        let mut single = Trail::start(EntityRef::Recording(RecordingId(1)), None, 0);
        single.follow(0, EntityRef::Agent(AgentId(10)), via(ThreadKind::ComposedBy), MIN);
        assert!(single.go(0, 2 * MIN));
        assert!(!single.sibling(1, 3 * MIN), "a stop with one branch leaving it isn't a fork");
    }

    #[test]
    fn restored_history_opens_on_today_and_back_enters_newest_saved_stop() {
        let mut first = Trail::start(EntityRef::Search, Some("first".into()), 0);
        first.follow(0, EntityRef::Release(ReleaseId(1)), via(ThreadKind::Matched), MIN);
        let mut newest = Trail::start(EntityRef::Search, Some("newest".into()), 2 * MIN);
        newest.follow(0, EntityRef::Release(ReleaseId(2)), via(ThreadKind::Matched), 3 * MIN);
        let mut history = TrailHistory::restore(vec![
            Trail::restore(first.uid, first.name, first.root_query, first.kept, first.stops, first.current, 10 * MIN),
            Trail::restore(newest.uid, newest.name, newest.root_query, newest.kept, newest.stops, newest.current, 10 * MIN),
        ]);
        assert!(history.current().is_none());
        assert!(!history.forward(10 * MIN));
        assert!(history.back(20 * MIN));
        let trail = history.current().unwrap();
        assert_eq!(trail.root_query.as_deref(), Some("newest"));
        assert_eq!(trail.current(), 1, "Today's back enters the trail where it was left");
        assert_eq!(trail.last_visited(), 3 * MIN, "entering it again isn't a move in it");
        assert_eq!(trail.snapshot(21 * MIN).stop(1).dwell_ms, MIN, "closed time isn't dwell");
    }

    #[test]
    fn stops_that_count_leave_out_peeks_and_the_time_is_the_current_stops() {
        let (t, [.., creid, _]) = tuesday();
        assert_eq!(t.visible(40 * MIN).len(), t.len() - 1, "the one peek doesn't count");
        assert_eq!(t.last_visited(), t.stop(creid).opened_at);
    }

    #[test]
    fn depth_first_visits_every_stop_once() {
        let (t, _) = tuesday();
        let order = t.depth_first();
        assert_eq!(order.len(), t.len());
        assert_eq!(order[0], 0);
    }
}
