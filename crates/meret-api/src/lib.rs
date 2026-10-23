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
use meret_model::{AgentId, EntityRef, GameId, ReleaseId, WorkId};
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
        let mut front = self.core.front().map(FrontDto::from).map_err(|e| e.to_string())?;
        let setting = self.core.settings().lookups;
        if setting == meret_core::Lookups::Unasked {
            let summary = self.core.lookup_summary().map_err(|e| e.to_string())?;
            if summary.releases + summary.recordings + summary.people + summary.unidentified > 0 {
                front.lookups = Some(LookupStatusDto::new(setting, summary));
            }
        }
        Ok(front)
    }

    /// Settings › Lookups: the answer, what the tags carry, and what's been looked up.
    pub fn lookups(&self) -> Result<LookupStatusDto, String> {
        let summary = self.core.lookup_summary().map_err(|e| e.to_string())?;
        Ok(LookupStatusDto::new(self.core.settings().lookups, summary))
    }

    /// Answers the lookup question, from the Front or Settings.
    pub fn set_lookups(&self, lookups: LookupsDto) -> Result<(), String> {
        let settings = meret_core::Settings { lookups: lookups.into(), ..self.core.settings() };
        self.core.set_settings(settings).map_err(|e| e.to_string())
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
            TransportDto::Resume => return self.core.resume().map_err(|e| e.to_string()),
            TransportDto::Seek { ms } => self.core.seek_ms(ms),
            TransportDto::Next => return self.core.next().map_err(|e| e.to_string()),
            TransportDto::Previous => return self.core.previous().map_err(|e| e.to_string()),
            TransportDto::Stop => self.core.stop(),
            TransportDto::FromStart => return self.core.from_start().map_err(|e| e.to_string()),
        }
        Ok(())
    }

    /// Writes the queue position and how far the open listen got, so quitting
    /// mid-track loses neither.
    pub fn flush_memory(&self) {
        self.core.flush_memory();
    }

    /// Adds a music folder and scans it in the background. Progress and the
    /// new track count arrive on the status stream.
    pub fn add_root(&self, path: &str) -> Result<i64, String> {
        self.core.add_root(Path::new(path)).map(|r| r.0).map_err(|e| e.to_string())
    }

    pub fn remove_root(&self, id: i64) -> Result<(), String> {
        self.core.remove_root(meret_model::RootId(id)).map_err(|e| e.to_string())
    }

    pub fn settings(&self) -> SettingsDto {
        self.core.settings().into()
    }

    /// Persists settings. Output changes wait for the next track while playing;
    /// when paused they apply on resume, and when idle on the next play.
    pub fn set_settings(&self, settings: SettingsDto) -> Result<(), String> {
        self.core.set_settings(settings.into()).map_err(|e| e.to_string())
    }

    pub fn output_devices(&self) -> Result<Vec<OutputDeviceDto>, String> {
        self.core.output_devices().map(|devices| devices.into_iter().map(Into::into).collect()).map_err(|e| e.to_string())
    }

    pub fn volume(&self) -> Result<VolumeDto, String> {
        self.core.volume().map(Into::into).map_err(|e| e.to_string())
    }

    pub fn set_volume(&self, scalar: f32) -> Result<VolumeDto, String> {
        self.core.set_volume(scalar).map(Into::into).map_err(|e| e.to_string())
    }

    pub fn suggest_folders(&self) -> Vec<FolderSuggestionDto> {
        self.core.suggest_folders().into_iter().map(Into::into).collect()
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

    /// Now's Up next: the queue after the playing item, up to `limit` rows.
    /// A row says why only when that differs from what's playing: a Play
    /// something queue carries its why on every item, and Now already says it.
    pub fn up_next(&self, limit: u32) -> Result<UpNextDto, String> {
        let (items, remaining) = self.core.up_next(limit as usize);
        let playing_why = self.now().why;
        let ids: Vec<_> = items.iter().filter_map(|i| i.track).collect();
        let mut rows: std::collections::HashMap<_, _> =
            self.core.store.track_rows(&ids).map_err(|e| e.to_string())?.into_iter().map(|r| (r.track, r)).collect();
        let items = items
            .into_iter()
            .map(|mut item| {
                if item.why == playing_why { item.why = None; }
                match item.track.and_then(|t| rows.remove(&t)) {
                    Some(r) => UpNextItemDto {
                        token: item.token,
                        track_id: Some(r.track.0),
                        title: r.title,
                        subtitle: [r.artist.as_deref(), Some(r.album.as_str())].into_iter().flatten().collect::<Vec<_>>().join(" · "),
                        length_ms: r.length_ms,
                        why: item.why,
                    },
                    None => {
                        let path = Path::new(item.uri.strip_prefix("file://").unwrap_or(&item.uri));
                        UpNextItemDto {
                            token: item.token,
                            track_id: item.track.map(|t| t.0),
                            title: path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default(),
                            subtitle: path.parent().map(|p| p.display().to_string()).unwrap_or_default(),
                            length_ms: None,
                            why: item.why,
                        }
                    }
                }
            })
            .collect();
        Ok(UpNextDto { items, remaining: remaining as u64 })
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
        let t = self.core.trail.lock().current()?.clone();
        Some(self.trail_dto(&t))
    }

    /// Keeps the current trail in session history and roots a new one at
    /// `to`: a search from the query line or a door on the Front.
    pub fn start_trail(&self, to: TargetDto) -> TrailDto {
        let (entity, root_query) = to.entity();
        let now = now_ms();
        let t = {
            let mut history = self.core.trail.lock();
            history.start(meret_graph::Trail::start(entity, root_query, now), now).clone()
        };
        if let Err(error) = self.core.save_trail_history() {
            tracing::error!(%error, "saving trail history");
        }
        self.trail_dto(&t)
    }

    /// Follows a thread from stop `from_stop`, the pane it was picked in.
    /// From a pane before the last, this starts a branch. `provider` is the
    /// thread's `provider`, so the strip can say where it came from.
    pub fn follow(&self, from_stop: u32, to: TargetDto, via: ThreadKind, provider: &str) -> Result<TrailDto, String> {
        let source = match (via, provider) {
            (ThreadKind::Matched, "library") => "library",
            (ThreadKind::Matched, _) => return Err("a search's hits are followed from the library".into()),
            (_, LOCAL_TAGS) => LOCAL_TAGS,
            (_, MUSICBRAINZ) => MUSICBRAINZ,
            (_, WIKIDATA) => WIKIDATA,
            (kind, other) => return Err(format!("\"{}\" threads from {other} aren't built yet", kind.label())),
        };
        if matches!(to, TargetDto::Search { .. }) {
            return Err("a search starts a trail; it isn't followed to".into());
        }
        let t = {
            let mut guard = self.core.trail.lock();
            let trail = guard.current_mut().ok_or("there's no trail to follow from")?;
            if from_stop as usize >= trail.len() {
                return Err(format!("the trail has no stop {from_stop}"));
            }
            let via = meret_graph::Via { kind: via, source: source.into() };
            trail.follow(from_stop as usize, to.entity().0, via, now_ms());
            trail.clone()
        };
        self.core.save_trails().map_err(|e| e.to_string())?;
        Ok(self.trail_dto(&t))
    }

    /// `[`: one stop back, or the previous trail's saved stop at the root.
    pub fn trail_back(&self) -> Option<TrailDto> {
        self.move_history(|history, now| history.back(now))
    }

    /// `]`: the next trail's root at a saved departure stop, otherwise the
    /// newest child that hasn't folded into a peek.
    pub fn trail_forward(&self) -> Option<TrailDto> {
        self.move_history(|history, now| history.forward(now))
    }

    /// A star on the strip, clicked: that stop becomes current.
    pub fn trail_go(&self, stop: u32) -> Result<TrailDto, String> {
        self.move_along(|t, now| t.go(stop as usize, now)).ok_or_else(|| format!("the trail has no stop {stop}"))
    }

    /// `⌥]` (`step` 1) and `⌥[` (`step` -1): the neighbouring branch at the
    /// nearest fork above the current stop. None with no fork above.
    pub fn trail_sibling(&self, step: i32) -> Option<TrailDto> {
        self.move_along(|t, now| t.sibling(step.signum() as isize, now))
    }

    /// `⌘⌫` or a branch's prune: hides the branch ending at stop `leaf`.
    /// Refused for the current branch and one with something done on it.
    pub fn prune_branch(&self, leaf: u32) -> Result<TrailDto, String> {
        let t = {
            let mut history = self.core.trail.lock();
            let trail = history.current_mut().ok_or("there's no trail to prune")?;
            let branch = trail
                .branches(now_ms())
                .into_iter()
                .find(|b| b.leaf == leaf as usize)
                .ok_or_else(|| format!("no branch ends at stop {leaf}"))?;
            trail.prune(&branch).map_err(|e| e.to_string())?;
            trail.clone()
        };
        self.core.save_trails().map_err(|e| e.to_string())?;
        Ok(self.trail_dto(&t))
    }

    /// Plays this branch, root to the current stop, or with `whole` the
    /// tree depth first. Returns how many tracks were queued.
    pub fn play_trail(&self, whole: bool) -> Result<u32, String> {
        self.core.play_trail(whole).map(|n| n as u32).map_err(|e| e.to_string())
    }

    /// A trail picked on the Front becomes active at the stop it was left on.
    pub fn open_trail(&self, uid: &str) -> Result<TrailDto, String> {
        let uid = meret_model::TrailUid(uid.parse().map_err(|_| format!("{uid} isn't a trail id"))?);
        self.move_history(|history, now| history.open(&uid, now)).ok_or_else(|| "that trail is no longer in the history".to_string())
    }

    fn move_along(&self, step: impl FnOnce(&mut meret_graph::Trail, i64) -> bool) -> Option<TrailDto> {
        self.move_history(|history, now| history.current_mut().is_some_and(|trail| step(trail, now)))
    }

    fn move_history(&self, step: impl FnOnce(&mut meret_graph::TrailHistory, i64) -> bool) -> Option<TrailDto> {
        let previous = self.core.trail.lock().active_index();
        let t = {
            let mut history = self.core.trail.lock();
            if !step(&mut history, now_ms()) {
                return None;
            }
            history.current()?.clone()
        };
        if let Some(previous) = previous
            && Some(previous) != self.core.trail.lock().active_index()
            && let Err(error) = self.core.save_trail_at(previous)
        {
            tracing::error!(%error, "saving departed trail");
        }
        if let Err(error) = self.core.save_trails() {
            tracing::error!(%error, "saving trail navigation");
        }
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
                TargetDto::Work { id } => self.core.store.work_title(WorkId(*id)),
                TargetDto::Game { id } => self.core.store.game_title(GameId(*id)),
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

    /// A work pane.
    pub fn work(&self, id: i64) -> Result<WorkDto, String> {
        match self.core.work(WorkId(id)) {
            Ok(Some(page)) => Ok(page.into()),
            Ok(None) => Err("that work is gone".into()),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Plays a work's recordings from row `index`, replacing the queue.
    pub fn play_work(&self, id: i64, index: u32) -> Result<(), String> {
        self.core.play_work(WorkId(id), index as usize).map_err(|e| e.to_string())
    }

    /// A game pane.
    pub fn game(&self, id: i64) -> Result<GameDto, String> {
        match self.core.game(GameId(id)) {
            Ok(Some(page)) => Ok(page.into()),
            Ok(None) => Err("that game is gone".into()),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Plays a game's soundtracks from row `index`, replacing the queue.
    pub fn play_game(&self, id: i64, index: u32) -> Result<(), String> {
        self.core.play_game(GameId(id), index as usize).map_err(|e| e.to_string())
    }

    /// Plays a release's tracklist from row `index`, replacing the queue.
    /// Playing it from its pane, stop `from_stop`, marks that stop played,
    /// so its branch is kept.
    pub fn play_release(&self, id: i64, index: u32, from_stop: Option<u32>) -> Result<(), String> {
        self.core.play_release(ReleaseId(id), index as usize).map_err(|e| e.to_string())?;
        if let (Some(stop), Some(trail)) = (from_stop, self.core.trail.lock().current_mut())
            && (stop as usize) < trail.len()
            && trail.stop(stop as usize).entity == EntityRef::Release(ReleaseId(id))
        {
            trail.act(stop as usize, meret_graph::Action::Played);
        }
        self.core.save_trails().map_err(|e| e.to_string())?;
        Ok(())
    }

    /// What the query line shows as you type a search: people, releases
    /// and tracks, grouped. Ask again as the text changes; a slow answer for
    /// old text is the caller's to drop.
    pub fn search(&self, input: &str) -> Result<SearchDto, String> {
        self.core.search(input, NAME_HITS, TRACK_HITS).map(SearchDto::from).map_err(|e| e.to_string())
    }
}

impl Api {
    /// The Front's saved trees, newest history position first.
    pub fn trail_history(&self, limit: u32) -> Result<Vec<TrailSummaryDto>, String> {
        self.core.store.trail_summaries(limit).map_err(|e| e.to_string())?.into_iter().map(|summary| {
            let title = |entity| -> Result<String, String> {
                let name = match entity {
                    EntityRef::Search => return Ok(summary.root_query.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| "Everything".into())),
                    EntityRef::Release(id) => self.core.store.release_title(id),
                    EntityRef::Agent(id) => self.core.store.agent_name(id),
                    EntityRef::Work(id) => self.core.store.work_title(id),
                    EntityRef::Game(id) => self.core.store.game_title(id),
                    _ => return Ok("gone".into()),
                };
                Ok(name.map_err(|e| e.to_string())?.unwrap_or_else(|| "gone".into()))
            };
            let root = title(summary.root)?;
            let leaf = title(summary.leaf)?;
            Ok(TrailSummaryDto {
                uid: summary.uid.to_string(), name: summary.name,
                title: if summary.root == summary.leaf { root } else { format!("{root} → {leaf}") },
                stops: summary.stops, branches: summary.branches, when_ms: summary.created_at,
                kept: summary.kept, played: summary.played, wanted: summary.wanted,
            })
        }).collect()
    }

    /// Keeps the whole active tree, optionally naming it.
    pub fn keep_trail(&self, name: Option<String>) -> Result<TrailDto, String> {
        let trail = {
            let mut history = self.core.trail.lock();
            let trail = history.current_mut().ok_or("there's no trail to keep")?;
            trail.kept = true;
            trail.name = name;
            trail.clone()
        };
        self.core.save_trails().map_err(|e| e.to_string())?;
        Ok(self.trail_dto(&trail))
    }

    pub fn resume_points(&self, limit: u32) -> Result<Vec<ResumeDto>, String> {
        let art_dir = self.core.art_dir();
        self.core.resume_points(limit as usize)
            .map(|rows| rows.into_iter().map(|row| ResumeDto::from_row(row, &art_dir)).collect())
            .map_err(|e| e.to_string())
    }

    pub fn pick_up(&self, release_id: i64) -> Result<(), String> {
        self.core.pick_up(ReleaseId(release_id)).map_err(|e| e.to_string())
    }
}

/// How many people and releases the query line shows, and how many tracks.
const NAME_HITS: usize = 5;
const TRACK_HITS: usize = 8;
/// How many picks Now shows, and how far `play_pick` looks for a clicked one.
pub const PICKS_SHOWN: u32 = 3;

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

impl Api {
    /// What was that? Every listen, newest first, whether it counted or not.
    pub fn history(&self, limit: u32) -> Result<Vec<ListenDto>, String> {
        let art_dir = self.core.art_dir();
        self.core.store.history(limit).map(|rows| rows.into_iter().map(|row| ListenDto::from_listen(row, &art_dir)).collect())
            .map_err(|e| e.to_string())
    }

    /// Counted plays in the last `days`, ranked by play count then recency.
    pub fn most_played(&self, days: u32, limit: u32) -> Result<Vec<PlayedDto>, String> {
        let art_dir = self.core.art_dir();
        let since_ms = now_ms() - i64::from(days) * 86_400_000;
        self.core.store.most_played(since_ms, limit).map(|rows| rows.into_iter().map(|row| PlayedDto::from_played(row, &art_dir)).collect())
            .map_err(|e| e.to_string())
    }

    /// Releases with five counted plays, then none in the last 180 days.
    pub fn dormant(&self, limit: u32) -> Result<Vec<DormantDto>, String> {
        let art_dir = self.core.art_dir();
        self.core.store.dormant(limit).map(|rows| rows.into_iter().map(|row| DormantDto::from_dormant(row, &art_dir)).collect())
            .map_err(|e| e.to_string())
    }

    /// Play something's picks, best first, each saying why (plate 09).
    pub fn picks(&self, limit: u32) -> Result<Vec<PickDto>, String> {
        let now = now_ms();
        let art_dir = self.core.art_dir();
        self.core.picks(limit as usize, now).map_err(|e| e.to_string())?.into_iter().map(|pick| {
            let page = self.core.store.release_page(pick.release).map_err(|e| e.to_string())?
                .ok_or_else(|| "that release is gone".to_owned())?;
            Ok(PickDto::new(pick, ReleaseDto::from_page(page, &art_dir), now))
        }).collect()
    }

    /// `⇧Space`: plays the first pick from the top and returns it; `None`
    /// when the library has nothing playable.
    pub fn play_something(&self) -> Result<Option<PickDto>, String> {
        let Some(pick) = self.picks(1)?.into_iter().next() else { return Ok(None) };
        self.core.play_pick(ReleaseId(pick.release_id), pick.why()).map_err(|e| e.to_string())?;
        Ok(Some(pick))
    }

    /// A pick clicked in Now: plays that release from the top with its why.
    pub fn play_pick(&self, release_id: i64) -> Result<PickDto, String> {
        let pick = self.picks(PICKS_SHOWN)?.into_iter().find(|pick| pick.release_id == release_id)
            .ok_or_else(|| "that pick is gone".to_owned())?;
        self.core.play_pick(ReleaseId(release_id), pick.why()).map_err(|e| e.to_string())?;
        Ok(pick)
    }

    /// Play on: every zone and what it does to the sound.
    pub fn zones(&self) -> Result<Vec<ZoneDto>, String> {
        self.core.zones().map(|zones| zones.into_iter().map(Into::into).collect()).map_err(|e| e.to_string())
    }

    /// Sends output to a zone; while playing it applies from the next track.
    pub fn play_on(&self, zone: String) -> Result<(), String> {
        self.core.play_on(&zone).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod trail_memory_tests {
    use super::*;

    #[test]
    fn api_walk_reopens_on_front_and_restores_the_same_dto_and_kept_summary() {
        let dir = std::env::temp_dir().join(format!("meret-api-trails-{}-{}", std::process::id(), now_ms()));
        let core = meret_core::start(meret_core::CoreConfig {
            data_dir: dir.clone(), output: meret_core::OutputChoice::Null { speed: 1.0 }, contact: "test".into(),
        }).unwrap();
        core.runtime.block_on(core.scans_settled()).unwrap();
        core.store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO release(id,title,idiom,rev) VALUES(1,'Fixture release',0,1);
                 INSERT INTO agent(id,kind,name,rev) VALUES(1,0,'Fixture person',1);",
            )?;
            Ok(())
        }).unwrap();
        let api = Api::new(core.clone());
        api.start_trail(TargetDto::Search { query: "older".into() });
        let root = api.start_trail(TargetDto::Search { query: "fixture".into() });
        let release = api.follow(root.current, TargetDto::Release { id: 1 }, ThreadKind::Matched, "library").unwrap();
        api.follow(release.current, TargetDto::Person { id: 1 }, ThreadKind::By, LOCAL_TAGS).unwrap();
        let expected = api.keep_trail(Some("Fixture tree".into())).unwrap();
        let before = api.trail_history(10).unwrap();
        assert_eq!(before.len(), 2);
        assert_eq!(before[0].title, "fixture → Fixture person");
        assert_eq!(before[0].stops, 3);
        assert!(before[0].kept);
        let reopened = meret_store::Store::open(&dir.join("library.db")).unwrap();
        *core.trail.lock() = meret_graph::TrailHistory::restore(reopened.load_trails().unwrap());
        assert!(api.trail().is_none());
        assert!(api.trail_forward().is_none());
        assert_eq!(api.trail_back(), Some(expected));
        assert_eq!(api.trail_history(10).unwrap(), before);
        assert_eq!(api.trail_back().unwrap().current, release.current);
        assert_eq!(reopened.load_trails().unwrap()[1].0.current(), release.current as usize);
        drop(reopened);
        branches_switch_with_alt_brackets_and_only_a_branch_you_left_prunes(&core, &api, &dir);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Runs inside the test above: the core is one per process.
    fn branches_switch_with_alt_brackets_and_only_a_branch_you_left_prunes(core: &Arc<meret_core::Core>, api: &Api, dir: &std::path::Path) {
        core.store.writer.write(|tx| tx.execute_batch(
            "INSERT INTO agent(id,kind,name,rev) VALUES(2,0,'Fixture one',1), (3,0,'Fixture two',1);",
        )).unwrap();
        let (minute, t0) = (60_000, now_ms() - 10 * 60_000);
        let by = || meret_graph::Via { kind: ThreadKind::By, source: LOCAL_TAGS.into() };
        let mut trail = meret_graph::Trail::start(EntityRef::Search, Some("branches".into()), t0);
        let uid = trail.uid;
        let release = trail.follow(0, EntityRef::Release(ReleaseId(1)), meret_graph::Via { kind: ThreadKind::Matched, source: "library".into() }, t0 + minute);
        let one = trail.follow(release, EntityRef::Agent(AgentId(2)), by(), t0 + 2 * minute);
        trail.back(t0 + 3 * minute);
        let two = trail.follow(release, EntityRef::Agent(AgentId(3)), by(), t0 + 4 * minute);
        core.trail.lock().start(trail, t0);

        let dto = api.trail().unwrap();
        let leaves: Vec<_> = dto.branches.iter().map(|b| (b.fork, b.leaf, b.current, b.prunable)).collect();
        assert_eq!(leaves, [(Some(release as u32), two as u32, true, false), (Some(release as u32), one as u32, false, true)]);
        assert!(api.prune_branch(two as u32).is_err(), "the current branch stays");

        assert_eq!(api.trail_sibling(1).unwrap().current, one as u32);
        let pruned = api.prune_branch(two as u32).unwrap();
        assert!(pruned.stops.iter().all(|s| s.index != two as u32));
        assert_eq!(pruned.branches.len(), 1);
        assert!(api.trail_sibling(1).is_none(), "no fork left");
        let saved = meret_store::Store::open(&dir.join("library.db")).unwrap().load_trails().unwrap();
        assert!(saved.iter().find(|t| t.0.uid == uid).unwrap().0.stop(two).pruned);
        assert!(api.play_trail(true).is_err(), "nothing here has a file");
    }
}
