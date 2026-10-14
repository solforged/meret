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
            Ok(Input::Command(c)) => {
                QueryDto { kind: QueryKind::Command, canonical: format!("{c:?}"), error: None }
            }
            Err(e) => QueryDto { kind: QueryKind::Invalid, canonical: String::new(), error: Some(e.to_string()) },
        }
    }

    /// A column header's histogram for the rows matching `query`.
    pub fn histogram(&self, column: ColumnDto, query: &str, lo: f64, hi: f64, bins: u32) -> HistogramDto {
        let cols = self.core.columns.read();
        let rows = match parse(query) {
            Ok(Input::Search(q)) => plan(&q, &cols, now_s()).rows.unwrap_or_else(|| cols.all()),
            _ => cols.all(),
        };
        let h = cols.histogram(column.into(), &rows, lo, hi, bins as usize);
        HistogramDto { lo: h.lo, hi: h.hi, bins: h.bins, matched: rows.len() }
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

    /// A search from the query line ends the trail and roots a new one at
    /// the search (decided 2026-10-13).
    pub fn start_trail_from_search(&self, query: &str, root: EntityRef) -> TrailDto {
        let now = now_ms();
        let t = meret_graph::Trail::start(root, Some(query.into()), now);
        // TODO(core): persist the old trail before replacing it.
        let dto = TrailDto::from_trail(&t, now);
        *self.core.trail.lock() = Some(t);
        dto
    }
}

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
