//! The one public surface. The Flutter UI reaches it through `meret-ffi`; a
//! phone reaches the hub's through a websocket (later). Everything here is
//! plain data, so either transport can carry it.
//!
//! Rules for callers: nothing here is called from a frame callback. Live
//! state (Now, the status line) is subscribed to, and the UI extrapolates the
//! playhead from `AnchorDto` itself.

mod dto;

use std::path::Path;
use std::sync::Arc;

use meret_core::Core;
use meret_model::{EntityRef, ThreadKind};
use meret_query::{Input, parse};
use meret_store::{ColumnId, plan};

pub use dto::*;

#[derive(Clone)]
pub struct Api {
    core: Arc<Core>,
}

impl Api {
    pub fn new(core: Arc<Core>) -> Self {
        Self { core }
    }

    /// Parses the query line as you type: is it a search or a command, what
    /// does it normalise to, and what's wrong with it.
    pub fn parse_query(&self, input: &str) -> QueryDto {
        match parse(input) {
            Ok(Input::Search(q)) => QueryDto { kind: QueryKind::Search, canonical: q.to_string(), error: None },
            Ok(Input::Command(c)) => QueryDto { kind: QueryKind::Command, canonical: c.to_string(), error: None },
            Err(e) => QueryDto { kind: QueryKind::Invalid, canonical: String::new(), error: Some(e.to_string()) },
        }
    }

    /// A column header's histogram for the rows matching `query`.
    pub fn histogram(&self, column: ColumnDto, query: &str, lo: f64, hi: f64, bins: u32) -> HistogramDto {
        let cols = self.core.columns.read();
        let rows = match parse(query) {
            Ok(Input::Search(q)) => self.core.store.answer_residual(plan(&q, &cols, now_s()), &cols).ok().flatten(),
            _ => None,
        }
        .unwrap_or_else(|| cols.all());
        let h = cols.histogram(column.into(), &rows, lo, hi, bins as usize);
        HistogramDto { lo: h.lo, hi: h.hi, bins: h.bins, matched: rows.len() }
    }

    /// The Front. Ask again when the status line's `library_version` moves.
    pub fn front(&self) -> Result<FrontDto, String> {
        self.core.front().map(FrontDto::from).map_err(|e| e.to_string())
    }

    /// Runs a command from the query line. `play <query>` plays what
    /// matches from the top; the other commands aren't built yet and say so.
    pub fn run_command(&self, input: &str) -> Result<(), String> {
        match parse(input).map_err(|e| e.to_string())? {
            Input::Command(meret_query::Command::Play { query }) => {
                self.core.play_results(&query.to_string(), 0).map_err(|e| e.to_string())
            }
            Input::Command(c) => Err(format!("{} isn't built yet", verb(&c))),
            Input::Search(_) => Err("a search, not a command".into()),
        }
    }

    pub fn transport(&self, cmd: TransportDto) -> Result<(), String> {
        match cmd {
            TransportDto::PlayFile { path } => return self.core.play_file(Path::new(&path)).map_err(|e| e.to_string()),
            TransportDto::Pause => self.core.pause(),
            TransportDto::Resume => self.core.resume(),
            TransportDto::Seek { ms } => self.core.seek_ms(ms),
            TransportDto::Stop => self.core.stop(),
        }
        Ok(())
    }

    /// Adds a music folder and scans it in the background. Progress and the
    /// new track count arrive on the status stream.
    pub fn add_root(&self, path: &str) -> Result<i64, String> {
        self.core.add_root(Path::new(path)).map(|r| r.0).map_err(|e| e.to_string())
    }

    pub fn rescan(&self) {
        self.core.rescan();
    }

    /// Rows `offset..offset + limit` of the table for `query`, in library
    /// order. An empty query is everything.
    pub fn rows(&self, query: &str, offset: u64, limit: u32) -> Result<RowsDto, String> {
        let (total, rows) = self.core.rows(query, offset as usize, limit as usize).map_err(|e| e.to_string())?;
        Ok(RowsDto { total: total as u64, offset, rows: rows.into_iter().map(TrackRowDto::from).collect() })
    }

    /// Replaces the queue with `query`'s result and plays from row `index`.
    pub fn play_results(&self, query: &str, index: u64) -> Result<(), String> {
        self.core.play_results(query, index as usize).map_err(|e| e.to_string())
    }

    /// Every engine event in order, for tools that check playback itself
    /// (gapless joins, Started and Ended order). The UI uses Now instead.
    pub fn subscribe_events(&self) -> tokio::sync::broadcast::Receiver<meret_engine::EngineEvent> {
        self.core.events()
    }

    /// Resolves once every scan queued so far has finished and the table
    /// shows its result.
    pub fn scans_settled(&self) -> tokio::sync::oneshot::Receiver<()> {
        self.core.scans_settled()
    }

    /// Each queued item's token and URI, in order.
    pub fn queue(&self) -> Vec<(u64, String)> {
        self.core.queue().into_iter().map(|i| (i.token, i.uri)).collect()
    }

    pub fn now(&self) -> NowDto {
        NowDto::from(&*self.core.now().borrow())
    }

    /// Waits for Now to change, then returns it.
    pub async fn now_changed(&self, rx: &mut tokio::sync::watch::Receiver<meret_core::NowState>) -> Option<NowDto> {
        rx.changed().await.ok()?;
        Some(NowDto::from(&*rx.borrow()))
    }

    pub fn subscribe_now(&self) -> tokio::sync::watch::Receiver<meret_core::NowState> {
        self.core.now()
    }

    pub fn status(&self) -> StatusDto {
        StatusDto::from(&*self.core.status().borrow())
    }

    pub fn subscribe_status(&self) -> tokio::sync::watch::Receiver<meret_core::StatusState> {
        self.core.status()
    }

    /// The trail strip: every stop and the thread into it.
    pub fn trail(&self) -> Option<TrailDto> {
        self.core.trail.lock().as_ref().map(|t| TrailDto::from_trail(t, now_ms()))
    }

    /// Follows a thread from a visible pane. Starts a trail if there isn't one.
    pub fn follow(&self, from_stop: Option<u32>, to: EntityRef, via: ThreadKind, source: &str) -> TrailDto {
        let mut guard = self.core.trail.lock();
        let now = now_ms();
        let trail = guard.get_or_insert_with(|| meret_graph::Trail::start(to, None, now));
        if let Some(from) = from_stop {
            trail.follow(from as usize, to, meret_graph::Via { kind: via, source: source.into() }, now);
        }
        TrailDto::from_trail(trail, now)
    }

    /// What the query line shows as you type a search: people, releases
    /// and tracks, grouped. Ask again as the text changes; a slow answer for
    /// old text is the caller's to drop.
    pub fn search(&self, input: &str) -> Result<SearchDto, String> {
        self.core.search(input, NAME_HITS, TRACK_HITS).map(SearchDto::from).map_err(|e| e.to_string())
    }

    /// A search from the query line ends the trail and roots a new one at
    /// the search (decided 2026-10-13).
    pub fn start_search_trail(&self, query: &str) -> TrailDto {
        let now = now_ms();
        let t = meret_graph::Trail::start(EntityRef::Search, Some(query.into()), now);
        // TODO(core): persist the old trail before replacing it.
        let dto = TrailDto::from_trail(&t, now);
        *self.core.trail.lock() = Some(t);
        dto
    }
}

/// How many people and releases the query line shows, and how many tracks.
const NAME_HITS: usize = 5;
const TRACK_HITS: usize = 8;

impl From<ColumnDto> for ColumnId {
    fn from(c: ColumnDto) -> Self {
        match c {
            ColumnDto::Year => ColumnId::Year,
            ColumnDto::Length => ColumnId::Length,
            ColumnDto::Plays => ColumnId::Plays,
            ColumnDto::LastPlayed => ColumnId::LastPlayed,
            ColumnDto::Added => ColumnId::Added,
            ColumnDto::Dr => ColumnId::Dr,
        }
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn now_s() -> i64 {
    now_ms() / 1000
}

fn verb(c: &meret_query::Command) -> &'static str {
    use meret_query::Command::*;
    match c {
        Play { .. } => "play",
        Queue { .. } => "queue",
        Want { .. } => "want",
        CrateAdd { .. } | CrateNew { .. } => "crate",
    }
}
