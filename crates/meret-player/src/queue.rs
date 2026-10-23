//! The queue. Shuffle obeys the idiom: works and sets are never split,
//! albums and sessions shuffle as whole releases.

use meret_model::idiom::{Idiom, ShufflePolicy};
use meret_model::{RecordingId, ReleaseId, StopUid, TrackId, WorkId};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct QueueItem {
    /// Unique within this queue; the engine's `ItemToken`.
    pub token: u64,
    /// What the zone plays: `file:///…` for a local file, a provider's URI
    /// otherwise.
    pub uri: String,
    /// Decode-side loudness levelling. Older saved queues play unchanged.
    #[serde(default)]
    pub gain_db: f64,
    /// None for a file played from outside the library.
    pub track: Option<TrackId>,
    pub recording: Option<RecordingId>,
    pub release: Option<ReleaseId>,
    /// For works: the parent work, so movements stay together.
    pub work: Option<WorkId>,
    pub idiom: Idiom,
    /// The trail stop this was queued from, so a listen can point back to it.
    pub from_stop: Option<StopUid>,
    /// "from Tuesday's trail", "the crate you play on 7 of 10 Tuesday evenings".
    pub why: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Queue {
    pub items: Vec<QueueItem>,
    pub cursor: usize,
    next_token: u64,
}

impl Queue {
    pub fn push(&mut self, mut item: QueueItem) -> u64 {
        self.next_token += 1;
        item.token = self.next_token;
        self.items.push(item);
        self.next_token
    }

    /// Builds a replacement without changing the current items or cursor.
    /// Reserves its tokens even if the replacement is never played.
    pub fn successor(&mut self, mut items: Vec<QueueItem>) -> Self {
        for item in &mut items {
            self.next_token += 1;
            item.token = self.next_token;
        }
        Self { items, cursor: 0, next_token: self.next_token }
    }

    /// Empties the queue. Tokens keep counting, so an engine event about an
    /// item from before can never be mistaken for one queued after.
    pub fn clear(&mut self) {
        self.items.clear();
        self.cursor = 0;
    }

    pub fn current(&self) -> Option<&QueueItem> {
        self.items.get(self.cursor)
    }

    pub fn up_next(&self) -> &[QueueItem] {
        self.items.get(self.cursor + 1..).unwrap_or(&[])
    }

    pub fn position_of(&self, token: u64) -> Option<usize> {
        self.items.iter().position(|i| i.token == token)
    }

    pub fn advance(&mut self) -> Option<&QueueItem> {
        if self.cursor + 1 < self.items.len() {
            self.cursor += 1;
            self.current()
        } else {
            None
        }
    }

    /// Shuffles what's after the cursor, keeping groups the idioms say must
    /// stay whole. Deterministic for a seed.
    pub fn shuffle(&mut self, seed: u64) {
        let rest = self.items.split_off(self.cursor + 1);
        let mut groups: Vec<Vec<QueueItem>> = vec![];
        for item in rest {
            let joins = groups.last().is_some_and(|g| same_group(&g[0], &item));
            if joins {
                groups.last_mut().expect("checked").push(item);
            } else {
                groups.push(vec![item]);
            }
        }
        let mut rng = seed | 1;
        for i in (1..groups.len()).rev() {
            rng ^= rng << 13;
            rng ^= rng >> 7;
            rng ^= rng << 17;
            groups.swap(i, (rng % (i as u64 + 1)) as usize);
        }
        self.items.extend(groups.into_iter().flatten());
    }
}

fn same_group(a: &QueueItem, b: &QueueItem) -> bool {
    match a.idiom.shuffle() {
        ShufflePolicy::Tracks => false,
        ShufflePolicy::Releases => a.release.is_some() && a.release == b.release,
        ShufflePolicy::Never => match (a.work, b.work) {
            (Some(x), Some(y)) => x == y,
            _ => a.release.is_some() && a.release == b.release,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(rec: i64, release: i64, work: Option<i64>, idiom: Idiom) -> QueueItem {
        QueueItem {
            token: 0,
            uri: String::new(),
            gain_db: 0.0,
            track: None,
            recording: Some(RecordingId(rec)),
            release: Some(ReleaseId(release)),
            work: work.map(WorkId),
            idiom,
            from_stop: None,
            why: None,
        }
    }

    #[test]
    fn saved_queue_gains_round_trip_and_old_items_default_to_zero() {
        let mut queued = item(1, 1, None, Idiom::Album);
        queued.gain_db = -3.25;
        let json = serde_json::to_string(&queued).unwrap();
        assert_eq!(serde_json::from_str::<QueueItem>(&json).unwrap(), queued);
        let mut old = serde_json::to_value(&queued).unwrap();
        old.as_object_mut().unwrap().remove("gain_db");
        assert_eq!(serde_json::from_value::<QueueItem>(old).unwrap().gain_db, 0.0);
    }

    #[test]
    fn shuffle_never_splits_a_work() {
        let mut q = Queue::default();
        q.push(item(0, 0, None, Idiom::Score));
        for m in 1..=4 {
            q.push(item(m, 7, Some(92), Idiom::Work)); // Beethoven 7, four movements
        }
        for t in 10..20 {
            q.push(item(t, t, None, Idiom::Score));
        }
        for seed in 1..50 {
            let mut s = q.clone();
            s.shuffle(seed);
            let pos: Vec<usize> =
                (1..=4).map(|m| s.items.iter().position(|i| i.recording == Some(RecordingId(m))).unwrap()).collect();
            assert_eq!(pos, vec![pos[0], pos[0] + 1, pos[0] + 2, pos[0] + 3], "seed {seed}");
        }
    }
}
