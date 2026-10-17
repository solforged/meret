//! Drives a zone from the queue: plays the current item, keeps the next one
//! loaded so the zone can join them without a gap, and moves along as items
//! end. It knows nothing of the engine; the local engine is one `Zone`.

use std::sync::Arc;

use crate::queue::{Queue, QueueItem};
use crate::zone::{Zone, ZoneCommand, ZoneError};

pub struct Player {
    queue: Queue,
    zone: Arc<dyn Zone>,
    /// The item handed to the zone as next, if any.
    next: Option<u64>,
    /// An item advanced to but not yet heard, which may have missed the join.
    awaiting_start: Option<u64>,
    /// Why the last item that was skipped couldn't play.
    last_error: Option<String>,
}

impl Player {
    pub fn new(zone: Arc<dyn Zone>) -> Self {
        Self { queue: Queue::default(), zone, next: None, awaiting_start: None, last_error: None }
    }

    pub fn queue(&self) -> &Queue {
        &self.queue
    }

    pub fn zone(&self) -> &Arc<dyn Zone> {
        &self.zone
    }

    /// Replaces the queue once a Play succeeds, skipping anything the zone
    /// can't open. An empty replacement stops playback.
    pub fn play(&mut self, items: Vec<QueueItem>, start: usize) -> Result<Option<&QueueItem>, ZoneError> {
        let mut replacement = self.queue.successor(items);
        if replacement.items.is_empty() {
            self.stop()?;
            self.queue = replacement;
            return Ok(None);
        }
        replacement.cursor = start.min(replacement.items.len() - 1);
        loop {
            let item = replacement.current().expect("cursor is in range");
            match self.zone.command(ZoneCommand::Play { item: item.token, uri: item.uri.clone(), start_ms: 0 }) {
                Ok(()) => break,
                Err(e @ ZoneError::CannotPlay(_)) => {
                    self.last_error = Some(e.to_string());
                    if replacement.advance().is_none() {
                        return Err(e);
                    }
                }
                Err(e) => return Err(e),
            }
        }
        self.queue = replacement;
        self.awaiting_start = None;
        self.preload();
        Ok(self.queue.current())
    }

    /// The zone finished `token`. If it was the current item, moves on to
    /// the one already loaded and loads the one after it. Returns the new
    /// current item, or None if the queue has run out or `token` is stale.
    pub fn ended(&mut self, token: u64) -> Option<&QueueItem> {
        if self.queue.current().map(|c| c.token) != Some(token) {
            return None;
        }
        self.awaiting_start = None;
        let at = self.next.take().and_then(|t| self.queue.position_of(t))?;
        self.queue.cursor = at;
        self.awaiting_start = self.queue.current().map(|c| c.token);
        self.preload();
        self.queue.current()
    }

    /// The zone made `token` audible. Events from old queues change nothing.
    pub fn started(&mut self, token: u64) {
        if self.awaiting_start == Some(token) {
            self.awaiting_start = None;
        }
    }

    /// Starts an unheard current item when its preload arrived too late.
    pub fn idle(&mut self) {
        let Some(token) = self.awaiting_start.take() else { return };
        let Some(item) = self.queue.current().filter(|c| c.token == token) else { return };
        match self.zone.command(ZoneCommand::Play { item: token, uri: item.uri.clone(), start_ms: 0 }) {
            Ok(()) => self.preload(),
            Err(e) => self.last_error = Some(e.to_string()),
        }
    }

    /// Skips to the first playable item after the cursor. At the end of the
    /// queue playback stops and the cursor stays; Ok(None) says so.
    pub fn next(&mut self) -> Result<Option<&QueueItem>, ZoneError> {
        if self.queue.cursor + 1 >= self.queue.items.len() {
            self.stop()?;
            return Ok(None);
        }
        self.jump(self.queue.cursor + 1, 1)
    }

    /// Plays the item before the cursor from its start; at the first item,
    /// the current one from its start. The caller decides when "previous"
    /// means "restart this one" instead.
    pub fn previous(&mut self) -> Result<Option<&QueueItem>, ZoneError> {
        self.jump(self.queue.cursor.saturating_sub(1), -1)
    }

    /// Moves the cursor to `at` and plays it, stepping on in `direction`
    /// past anything the zone can't open.
    fn jump(&mut self, at: usize, direction: isize) -> Result<Option<&QueueItem>, ZoneError> {
        let mut at = at;
        loop {
            let Some(item) = self.queue.items.get(at) else {
                self.stop()?;
                return Ok(None);
            };
            match self.zone.command(ZoneCommand::Play { item: item.token, uri: item.uri.clone(), start_ms: 0 }) {
                Ok(()) => break,
                Err(e @ ZoneError::CannotPlay(_)) => {
                    self.last_error = Some(e.to_string());
                    match at.checked_add_signed(direction) {
                        Some(step) => at = step,
                        None => {
                            self.stop()?;
                            return Ok(None);
                        }
                    }
                }
                Err(e) => return Err(e),
            }
        }
        self.queue.cursor = at;
        self.awaiting_start = None;
        self.preload();
        Ok(self.queue.current())
    }

    pub fn stop(&mut self) -> Result<(), ZoneError> {
        self.next = None;
        self.awaiting_start = None;
        self.zone.command(ZoneCommand::Stop)
    }

    pub fn take_error(&mut self) -> Option<String> {
        self.last_error.take()
    }

    /// Hands the zone the first playable item after the cursor.
    fn preload(&mut self) {
        self.next = None;
        for item in self.queue.up_next() {
            match self.zone.command(ZoneCommand::SetNext { item: item.token, uri: item.uri.clone() }) {
                Ok(()) => {
                    self.next = Some(item.token);
                    return;
                }
                Err(e) => self.last_error = Some(e.to_string()),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::zone::{ZoneFidelity, ZoneInfo, ZoneState};
    use meret_model::Idiom;
    use parking_lot::Mutex;

    #[derive(Default)]
    struct Recorder(Mutex<Vec<String>>);

    impl Zone for Recorder {
        fn info(&self) -> ZoneInfo {
            ZoneInfo {
                id: "test".into(),
                name: "Test".into(),
                detail: String::new(),
                host: "local".into(),
                fidelity: ZoneFidelity::BitPerfect,
                decodes_here: true,
            }
        }

        fn command(&self, cmd: ZoneCommand) -> Result<(), ZoneError> {
            let (verb, item, uri) = match &cmd {
                ZoneCommand::Play { item, uri, .. } => ("play", *item, uri.as_str()),
                ZoneCommand::SetNext { item, uri } => ("next", *item, uri.as_str()),
                ZoneCommand::Stop => {
                    self.0.lock().push("stop".into());
                    return Ok(());
                }
                _ => return Ok(()),
            };
            if uri == "bad" {
                return Err(ZoneError::CannotPlay(uri.into()));
            }
            self.0.lock().push(format!("{verb} {item}"));
            Ok(())
        }

        fn state(&self) -> ZoneState {
            ZoneState::default()
        }
    }

    fn items(uris: &[&str]) -> Vec<QueueItem> {
        uris.iter()
            .map(|u| QueueItem {
                token: 0,
                uri: (*u).into(),
                track: None,
                recording: None,
                release: None,
                work: None,
                idiom: Idiom::Album,
                from_stop: None,
                why: None,
            })
            .collect()
    }

    fn player() -> (Player, Arc<Recorder>) {
        let zone = Arc::new(Recorder::default());
        (Player::new(zone.clone()), zone)
    }

    fn log(z: &Recorder) -> Vec<String> {
        std::mem::take(&mut *z.0.lock())
    }

    #[test]
    fn keeps_the_next_item_loaded_as_each_one_ends() {
        let (mut p, z) = player();
        p.play(items(&["a", "b", "c"]), 1).unwrap();
        assert_eq!(log(&z), ["play 2", "next 3"]);
        assert_eq!(p.ended(2).map(|i| i.token), Some(3));
        assert!(log(&z).is_empty(), "nothing after the last item");
        assert_eq!(p.ended(3), None);
        assert_eq!(p.queue().cursor, 2);
    }

    #[test]
    fn an_end_from_a_replaced_queue_moves_nothing() {
        let (mut p, z) = player();
        p.play(items(&["a", "b"]), 0).unwrap();
        p.play(items(&["c", "d"]), 0).unwrap();
        log(&z);
        // The engine reports the old first item ending when the new one starts.
        assert_eq!(p.ended(1), None);
        assert_eq!(p.queue().current().map(|i| i.token), Some(3));
        assert_eq!(p.ended(3).map(|i| i.token), Some(4));
    }

    #[test]
    fn items_the_zone_cannot_open_are_skipped() {
        let (mut p, z) = player();
        p.play(items(&["bad", "a", "bad", "b"]), 0).unwrap();
        assert_eq!(log(&z), ["play 2", "next 4"]);
        assert!(p.take_error().is_some());
        assert_eq!(p.ended(2).map(|i| i.token), Some(4));
    }

    #[test]
    fn stopping_ends_the_queue() {
        let (mut p, _) = player();
        p.play(items(&["a", "b"]), 0).unwrap();
        p.stop().unwrap();
        // The engine reports the stopped item as ended.
        assert_eq!(p.ended(1), None);
        assert_eq!(p.queue().cursor, 0);
    }

    #[test]
    fn next_and_previous_move_the_cursor_and_reload_what_follows() {
        let (mut p, z) = player();
        p.play(items(&["a", "b", "c"]), 0).unwrap();
        log(&z);
        assert_eq!(p.next().unwrap().map(|i| i.token), Some(2));
        assert_eq!(log(&z), ["play 2", "next 3"]);
        assert_eq!(p.previous().unwrap().map(|i| i.token), Some(1));
        assert_eq!(log(&z), ["play 1", "next 2"]);
        // The engine reports the replaced item ending; the cursor doesn't move.
        assert_eq!(p.ended(2), None);
        assert_eq!(p.queue().cursor, 0);
        // At the first item, previous restarts it.
        assert_eq!(p.previous().unwrap().map(|i| i.token), Some(1));
        assert_eq!(log(&z), ["play 1", "next 2"]);
    }

    #[test]
    fn next_past_the_end_stops_and_skips_what_cannot_open() {
        let (mut p, z) = player();
        p.play(items(&["a", "bad", "b"]), 0).unwrap();
        log(&z);
        assert_eq!(p.next().unwrap().map(|i| i.token), Some(3));
        assert_eq!(log(&z), ["play 3"]);
        assert!(p.take_error().is_some());
        assert_eq!(p.next().unwrap(), None);
        assert_eq!(log(&z), ["stop"]);
        assert_eq!(p.queue().cursor, 2);
        // Previous from the last item steps over the bad one too.
        assert_eq!(p.previous().unwrap().map(|i| i.token), Some(1));
        assert_eq!(log(&z), ["play 1", "next 3"]);
    }

    #[test]
    fn idle_starts_an_item_whose_preload_missed_the_join() {
        let (mut p, z) = player();
        p.play(items(&["a", "b", "c", "d"]), 0).unwrap();
        p.started(1);
        p.ended(1);
        p.started(2);
        // Opening C during Ended(A) took longer than B had left to play.
        p.ended(2);
        assert_eq!(p.queue().current().map(|i| i.token), Some(3));
        assert_eq!(log(&z), ["play 1", "next 2", "next 3", "next 4"]);
        p.started(1);
        p.idle();
        assert_eq!(log(&z), ["play 3", "next 4"]);
        p.started(3);
        p.idle();
        assert!(log(&z).is_empty());
    }

    #[test]
    fn idle_does_not_restart_an_item_that_started() {
        let (mut p, z) = player();
        p.play(items(&["a", "b"]), 0).unwrap();
        p.started(1);
        p.ended(1);
        p.started(2);
        log(&z);
        p.idle();
        assert!(log(&z).is_empty());
        assert_eq!(p.ended(2), None);
        p.idle();
        assert!(log(&z).is_empty(), "the last item already played");
    }

    #[test]
    fn idle_does_not_restart_a_stopped_preload() {
        let (mut p, z) = player();
        p.play(items(&["a", "b", "c"]), 0).unwrap();
        p.started(1);
        p.ended(1);
        log(&z);
        p.stop().unwrap();
        p.ended(2);
        p.idle();
        assert_eq!(log(&z), ["stop"]);
    }

    #[test]
    fn idle_from_a_replaced_queue_does_not_restart_the_replacement() {
        let (mut p, z) = player();
        p.play(items(&["a", "b"]), 0).unwrap();
        p.started(1);
        p.ended(1);
        p.play(items(&["c", "d"]), 0).unwrap();
        log(&z);
        p.started(2);
        assert_eq!(p.ended(2), None);
        p.idle();
        assert_eq!(p.queue().current().map(|i| i.token), Some(3));
        assert!(log(&z).is_empty());
    }

    #[test]
    fn an_unplayable_replacement_keeps_the_old_queue_and_preload() {
        let (mut p, z) = player();
        p.play(items(&["a", "b", "c"]), 0).unwrap();
        p.started(1);
        log(&z);
        assert!(matches!(p.play(items(&["bad", "bad"]), 0), Err(ZoneError::CannotPlay(_))));
        assert_eq!(p.queue().current().map(|i| i.token), Some(1));
        assert_eq!(p.queue().items.len(), 3);
        assert!(log(&z).is_empty());
        assert_eq!(p.ended(1).map(|i| i.token), Some(2));
        assert_eq!(log(&z), ["next 3"]);
        p.started(2);
        assert_eq!(p.ended(2).map(|i| i.token), Some(3));
        // Failed replacements reserve their tokens too.
        assert_eq!(p.play(items(&["d"]), 0).unwrap().map(|i| i.token), Some(6));
        assert_eq!(log(&z), ["play 6"]);
    }

    #[test]
    fn an_empty_replacement_stops_and_empties_the_queue() {
        let (mut p, z) = player();
        p.play(items(&["a", "b"]), 0).unwrap();
        p.started(1);
        p.ended(1);
        log(&z);
        assert_eq!(p.play(vec![], 0).unwrap(), None);
        assert!(p.queue().items.is_empty());
        assert_eq!(p.ended(2), None);
        p.idle();
        assert_eq!(log(&z), ["stop"]);
        assert_eq!(p.play(items(&["c"]), 0).unwrap().map(|i| i.token), Some(3));
    }
}
