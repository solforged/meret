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
use meret_core::{PageItem, View};
use meret_model::{AgentId, EntityRef, ReleaseId};
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
                self.core.play_results(&query.to_string(), &View::default(), 0).map_err(|e| e.to_string())
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

    /// Display items `offset..offset + limit` of this query and view.
    pub fn rows(&self, query: &str, view: ViewDto, offset: u64, limit: u32) -> Result<RowsDto, String> {
        let page = self.core.rows(query, &view.into(), offset as usize, limit as usize).map_err(|e| e.to_string())?;
        let art_dir = self.core.art_dir();
        Ok(RowsDto {
            total: page.total_items as u64,
            tracks: page.tracks as u64,
            releases: page.releases as u64,
            offset,
            items: page.items.into_iter().map(|item| match item {
                PageItem::Group(g) => ItemDto::Group(GroupDto::from_group(g, &art_dir)),
                PageItem::Track { ordinal, row } => ItemDto::Track { ordinal, row: row.into() },
            }).collect(),
        })
    }

    /// Replaces the queue from a track ordinal in the view's display order.
    pub fn play_results(&self, query: &str, view: ViewDto, index: u64) -> Result<(), String> {
        self.core.play_results(query, &view.into(), index as usize).map_err(|e| e.to_string())
    }

    pub fn facets(&self, query: &str) -> Result<FacetsDto, String> {
        self.core.facets(query).map(Into::into).map_err(|e| e.to_string())
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

    /// Cover reads since startup, including its background rescan.
    pub fn cover_report(&self) -> meret_library::CoverReport {
        self.core.cover_report()
    }

    /// Each queued item's token and URI, in order.
    pub fn queue(&self) -> Vec<(u64, String)> {
        self.core.queue().into_iter().map(|i| (i.token, i.uri)).collect()
    }

    pub fn now(&self) -> NowDto {
        NowDto::from_state(&self.core.now().borrow(), &self.core.art_dir())
    }

    /// Waits for Now to change, then returns it.
    pub async fn now_changed(&self, rx: &mut tokio::sync::watch::Receiver<meret_core::NowState>) -> Option<NowDto> {
        rx.changed().await.ok()?;
        Some(NowDto::from_state(&rx.borrow(), &self.core.art_dir()))
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
        let t = self.core.trail.lock().clone()?;
        Some(self.trail_dto(&t))
    }

    /// Ends the current trail and roots a new one at `to`: a search from the
    /// query line or a door on the Front.
    pub fn start_trail(&self, to: TargetDto) -> TrailDto {
        let (entity, root_query) = to.entity();
        let t = meret_graph::Trail::start(entity, root_query, now_ms());
        // TODO(core): persist the old trail before replacing it.
        *self.core.trail.lock() = Some(t.clone());
        self.trail_dto(&t)
    }

    /// Follows a thread from stop `from_stop`, the pane it was picked in.
    /// From a pane before the last, this starts a branch.
    pub fn follow(&self, from_stop: u32, to: TargetDto, via: ThreadKind) -> Result<TrailDto, String> {
        let source = match via {
            ThreadKind::By | ThreadKind::AlbumArtist | ThreadKind::AppearsOn | ThreadKind::WorkedWith => LOCAL_TAGS,
            ThreadKind::Matched => "library",
            other => return Err(format!("\"{}\" threads come with providers, which aren't built yet", other.label())),
        };
        if matches!(to, TargetDto::Search { .. }) {
            return Err("a search starts a trail; it isn't followed to".into());
        }
        let t = {
            let mut guard = self.core.trail.lock();
            let trail = guard.as_mut().ok_or("there's no trail to follow from")?;
            if from_stop as usize >= trail.len() {
                return Err(format!("the trail has no stop {from_stop}"));
            }
            let via = meret_graph::Via { kind: via, source: source.into() };
            trail.follow(from_stop as usize, to.entity().0, via, now_ms());
            trail.clone()
        };
        Ok(self.trail_dto(&t))
    }

    /// `[`: one stop back. None at the root, or with no trail.
    pub fn trail_back(&self) -> Option<TrailDto> {
        self.move_along(|t, now| t.back(now))
    }

    /// `]`: forward to the newest stop opened from this one. None when
    /// there's none.
    pub fn trail_forward(&self) -> Option<TrailDto> {
        self.move_along(|t, now| t.forward(now))
    }

    /// A star on the strip, clicked: that stop becomes current.
    pub fn trail_go(&self, stop: u32) -> Result<TrailDto, String> {
        self.move_along(|t, now| t.go(stop as usize, now)).ok_or_else(|| format!("the trail has no stop {stop}"))
    }

    fn move_along(&self, step: impl FnOnce(&mut meret_graph::Trail, i64) -> bool) -> Option<TrailDto> {
        let t = {
            let mut guard = self.core.trail.lock();
            let trail = guard.as_mut()?;
            if !step(trail, now_ms()) {
                return None;
            }
            trail.clone()
        };
        Some(self.trail_dto(&t))
    }

    /// Built outside the trail's lock: naming stops reads the store.
    fn trail_dto(&self, t: &meret_graph::Trail) -> TrailDto {
        TrailDto::from_trail(t, now_ms(), |target| {
            let name = match target {
                TargetDto::Search { query } if query.is_empty() => Ok(Some("Everything".into())),
                TargetDto::Search { query } => Ok(Some(query.clone())),
                TargetDto::Release { id } => self.core.store.release_title(ReleaseId(*id)),
                TargetDto::Person { id } => self.core.store.agent_name(AgentId(*id)),
            };
            name.ok().flatten().unwrap_or_else(|| "gone".into())
        })
    }

    /// A release pane.
    pub fn release(&self, id: i64) -> Result<ReleaseDto, String> {
        match self.core.release(ReleaseId(id)) {
            Ok(Some(page)) => Ok(ReleaseDto::from_page(page, &self.core.art_dir())),
            Ok(None) => Err("that release is gone".into()),
            Err(e) => Err(e.to_string()),
        }
    }

    /// A person pane.
    pub fn person(&self, id: i64) -> Result<PersonDto, String> {
        match self.core.person(AgentId(id)) {
            Ok(Some(page)) => Ok(page.into()),
            Ok(None) => Err("that person is gone".into()),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Plays a release's tracklist from row `index`, replacing the queue.
    /// Playing it from its pane, stop `from_stop`, marks that stop played,
    /// so its branch is kept.
    pub fn play_release(&self, id: i64, index: u32, from_stop: Option<u32>) -> Result<(), String> {
        self.core.play_release(ReleaseId(id), index as usize).map_err(|e| e.to_string())?;
        if let (Some(stop), Some(trail)) = (from_stop, self.core.trail.lock().as_mut())
            && (stop as usize) < trail.len()
            && trail.stop(stop as usize).entity == EntityRef::Release(ReleaseId(id))
        {
            trail.act(stop as usize, meret_graph::Action::Played);
        }
        Ok(())
    }

    /// What the query line shows as you type a search: people, releases
    /// and tracks, grouped. Ask again as the text changes; a slow answer for
    /// old text is the caller's to drop.
    pub fn search(&self, input: &str) -> Result<SearchDto, String> {
        self.core.search(input, NAME_HITS, TRACK_HITS).map(SearchDto::from).map_err(|e| e.to_string())
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
