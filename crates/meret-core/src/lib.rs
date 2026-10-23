//! The runtime: one per process, started by the platform host (the macOS app
//! delegate, Android's MediaSessionService) before any UI exists, so playback
//! never depends on a window. The UI attaches through `meret-api`.

mod analysis;
mod level;
mod facets;
mod local_zone;
mod listens;
mod games;
mod lookups;
mod matching;
mod now;
mod scan;
#[cfg(target_os = "macos")]
mod fswatch;
mod status;
mod suggestions;
mod views;
mod trails;
mod memory;
mod picks;

#[cfg(test)]
mod setup_tests;

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, OnceLock};

use crossbeam_channel::Sender;
use meret_engine::engine::EngineConfig;
use meret_engine::output::OutputBackend;
use meret_engine::output::null::NullBackend;
use meret_engine::{Engine, EngineEvent};
use meret_graph::TrailHistory;
use meret_jobs::Scheduler;
use meret_model::{AgentId, GameId, Idiom, ReleaseId, RootId, TrackId, WorkId};
use meret_player::{Player, QueueItem, Zone, ZoneCommand, ZoneError, ZoneFidelity, ZoneInfo};
use meret_provider::Registry;
use meret_query::{Input, Term, parse};
use meret_store::{HotColumns, LibraryFacts, PersonHit, ReleaseHit, Store, TrackRow};
pub use meret_store::{Colleague, GameLink, GamePage, OtherRecording, PersonLink, PersonPage, PersonRelease, PersonWork, ROLES, ReleasePage, RoleCredit, TrackCredit, WorkPage};
use parking_lot::{Mutex, RwLock};
use tokio::sync::{broadcast, watch};

pub use facets::{Facet, FacetColumn, Facets};
pub use local_zone::{LocalZone, file_uri};
pub use now::NowState;
pub use picks::{Pick, Why};
pub use status::{SourceStatus, StatusState};
pub use meret_store::{JobCounts, Level, LightLevel, Lookups, Settings};
pub use lookups::LookupSummary;
pub use suggestions::{FolderKind, FolderSuggestion};
pub use views::{GroupRow, Item, List, PageItem, RowsPage, SortKey, View};

use scan::ScanRequest;

/// How many results "play these" queues, from the row it starts at.
pub const MAX_QUEUE: usize = 10_000;

/// Past this, "previous" restarts the playing item instead of leaving it.
const PREVIOUS_RESTART_MS: u64 = 3_000;

/// A zone Play on lists, and whether output is set to it.
#[derive(Clone, Debug, PartialEq)]
pub struct ZoneRow {
    pub info: ZoneInfo,
    pub current: bool,
}

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error(transparent)]
    Store(#[from] meret_store::StoreError),
    #[error(transparent)]
    Scan(#[from] meret_library::ScanError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Zone(#[from] ZoneError),
    #[error("{0}")]
    Query(String),
    #[error(transparent)]
    Output(#[from] meret_engine::output::OutputError),
    #[error("the core is already running with a different data directory")]
    AlreadyStarted,
}

pub type Result<T, E = CoreError> = std::result::Result<T, E>;

#[derive(Clone, Debug)]
pub enum OutputChoice {
    /// Plays to nowhere; for tests, and on platforms without a backend yet.
    Null { speed: f64 },
    /// The platform's bit-perfect backend.
    System { device: Option<String>, exclusive: bool },
}

#[derive(Clone, Debug)]
pub struct CoreConfig {
    pub data_dir: PathBuf,
    pub output: OutputChoice,
    /// MusicBrainz asks for a contact in the User-Agent.
    pub contact: String,
}

/// See `Core::front`.
#[derive(Clone, Debug)]
pub struct Front {
    pub tracks: u64,
    /// Indexed by `Idiom as u8`; 0 is unknown.
    pub tracks_by_idiom: [u32; 8],
    /// Counts of the format doors' queries; tracks can appear in several doors.
    pub formats: [FrontFormatLine; 6],
    pub facts: LibraryFacts,
    pub roots: Vec<meret_library::Root>,
}

#[derive(Clone, Debug)]
pub struct FrontFormatLine {
    pub label: &'static str,
    pub count: u64,
    pub note: &'static str,
    pub query: Option<&'static str>,
}

/// Label, note and query for each format door, shared by its count and the UI.
const FRONT_FORMATS: [(&str, &str, Option<&str>); 6] = [
    ("Lossless, up to 16/48", "FLAC, ALAC, WAV, AIFF", Some("format:flac -format:hires")),
    ("Hi-res", "over 16 bit or 48 kHz", Some("format:hires")),
    ("DSD", "", Some("format:dsd")),
    ("Native chiptune", "SPC, NSF, VGM", Some("format:chiptune")),
    ("Lossy", "MP3, AAC, Ogg, Opus", Some("format:lossy")),
    ("Unknown format", "", None),
];

/// How long a list stays fresh when the library hasn't changed.
const LIST_TTL_S: i64 = 60;

/// How many lists are kept: the open tables plus the search being typed,
/// so typing doesn't throw away the list a table is paging through.
const LISTS: usize = 6;

/// See `Core::search`.
#[derive(Clone, Debug)]
pub struct Search {
    /// The search in canonical form; its result is `list(query)`.
    pub query: String,
    pub tracks: usize,
    pub people_total: u64,
    pub people: Vec<PersonHit>,
    pub releases_total: u64,
    pub releases: Vec<ReleaseHit>,
    /// Rows of the result whose own title has every free-text word, with
    /// their index in it; the first rows when there are no words.
    pub track_hits: Vec<(usize, TrackRow)>,
    /// How many rows of the result `track_hits` is the start of.
    pub track_hits_total: usize,
}

pub struct Core {
    pub config: CoreConfig,
    pub store: Store,
    pub columns: RwLock<HotColumns>,
    pub registry: Registry,
    pub scheduler: Mutex<Scheduler>,
    pub trail: Mutex<TrailHistory>,
    pub engine: Arc<Engine>,
    pub local: Arc<LocalZone>,
    pub player: Mutex<Player>,
    pub runtime: tokio::runtime::Runtime,
    now: watch::Sender<NowState>,
    status: watch::Sender<StatusState>,
    events: broadcast::Sender<EngineEvent>,
    scans: Sender<ScanRequest>,
    cover_report: Mutex<meret_library::CoverReport>,
    /// The HTTP client every lookup shares: per-host pacing and `cache.db`.
    http: meret_provider::Http,
    lookups_wake: Sender<()>,
    /// Taken by the runner when the core starts; tests never start one.
    lookups_wakes: Mutex<Option<crossbeam_channel::Receiver<()>>>,
    lookup_state: Mutex<lookups::State>,
    analysis_wake: parking_lot::Condvar,
    analysis_state: Mutex<analysis::State>,
    /// Keeps analysis commits and full column snapshots in publication order.
    analysis_write: Mutex<()>,
    lists: Mutex<VecDeque<Arc<List>>>,
    settings: Mutex<Settings>,
    open_listen: Mutex<Option<listens::Open>>,
    carried_listen: Mutex<Option<listens::Carried>>,
    device_id: String,
    pending: Mutex<Option<memory::Pending>>,
    memory_state: Mutex<memory::State>,
    /// Tells the FSEvents watcher the roots changed.
    #[cfg(target_os = "macos")]
    fswatch: OnceLock<Sender<fswatch::Message>>,
}

static CORE: OnceLock<Arc<Core>> = OnceLock::new();

/// Starts the process-wide core, or returns the running one. The hot
/// columns load in the background, and the roots catch up with what changed
/// since the last run.
pub fn start(mut config: CoreConfig) -> Result<Arc<Core>> {
    config.data_dir = std::path::absolute(config.data_dir)?;
    if let Some(c) = CORE.get() {
        return if c.config.data_dir == config.data_dir { Ok(c.clone()) } else { Err(CoreError::AlreadyStarted) };
    }
    let (scans, requests) = crossbeam_channel::unbounded();
    let core = Arc::new(Core::new(config, scans)?);
    memory::restore(&core)?;
    let core = CORE.get_or_init(|| core).clone();
    now::spawn_pump(core.clone());
    scan::spawn_worker(core.clone(), requests);
    lookups::spawn_runner(core.clone());
    analysis::spawn_runner(core.clone());
    let _ = core.scans.send(ScanRequest::LoadColumns);
    #[cfg(target_os = "macos")]
    fswatch::start(&core);
    #[cfg(not(target_os = "macos"))]
    let _ = core.scans.send(ScanRequest::AllRoots);
    Ok(core)
}

pub fn get() -> Option<Arc<Core>> {
    CORE.get().cloned()
}

impl Core {
    fn new(mut config: CoreConfig, scans: Sender<ScanRequest>) -> Result<Self> {
        let (lookups_wake, lookups_wakes) = crossbeam_channel::unbounded();
        std::fs::create_dir_all(&config.data_dir)?;
        let store = Store::open(&config.data_dir.join("library.db"))?;
        let cache = meret_store::HttpCache::open(&config.data_dir.join("cache.db"))?;
        let http = meret_provider::Http::new(&format!("Meret/{} ( {} )", env!("CARGO_PKG_VERSION"), config.contact))
            .with_cache(Arc::new(lookups::StoredResponses(cache)), lookups::CACHE_TTL_MS);
        let device_id = store.device_id()?;
        let saved = store.settings()?;
        let has_saved = saved.is_some();
        let settings = saved.unwrap_or_else(|| match &config.output {
            OutputChoice::System { device, exclusive } => Settings {
                output_device: device.clone(), exclusive: *exclusive, ..Settings::default()
            },
            OutputChoice::Null { .. } => Settings::default(),
        });
        if has_saved && matches!(config.output, OutputChoice::System { .. }) {
            config.output = OutputChoice::System { device: settings.output_device.clone(), exclusive: settings.exclusive };
        }
        tracing::debug!(has_saved, ?settings, output = ?config.output, "configuring local output");

        // TODO(core): load hot columns from a snapshot file first; the scan
        // worker loads them from SQLite after start-up.
        let columns = RwLock::new(HotColumns::default());

        let mut registry = Registry::default();
        registry.add(Arc::new(provider_musicbrainz::MusicBrainz));
        registry.add(Arc::new(provider_music_assistant::MusicAssistant { url: None }));

        let backend: Arc<dyn OutputBackend> = match &config.output {
            OutputChoice::Null { speed } => Arc::new(NullBackend { speed: *speed }),
            #[cfg(target_os = "macos")]
            OutputChoice::System { .. } => Arc::new(meret_engine::output::coreaudio::CoreAudioBackend),
            #[cfg(not(target_os = "macos"))]
            OutputChoice::System { .. } => Arc::new(NullBackend { speed: 1.0 }),
        };
        let engine_config = match &config.output {
            OutputChoice::System { device, exclusive } => {
                EngineConfig { device: device.clone(), exclusive: *exclusive, ..Default::default() }
            }
            OutputChoice::Null { .. } => EngineConfig::default(),
        };
        let engine = Arc::new(Engine::spawn(backend, engine_config));
        let local = Arc::new(LocalZone::new(engine.clone()));

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("meret-core")
            .enable_time()
            .enable_io()
            .build()?;

        let status = status::initial(&registry);
        let trails = TrailHistory::restore(store.load_trails()?);
        Ok(Self {
            config,
            store,
            columns,
            registry,
            scheduler: Mutex::new(Scheduler::default()),
            trail: Mutex::new(trails),
            engine,
            player: Mutex::new(Player::new(local.clone())),
            local,
            runtime,
            now: watch::channel(NowState::default()).0,
            status: watch::channel(status).0,
            events: broadcast::channel(256).0,
            scans,
            cover_report: Mutex::new(meret_library::CoverReport::default()),
            http,
            lookups_wake,
            lookups_wakes: Mutex::new(Some(lookups_wakes)),
            lookup_state: Mutex::new(lookups::State::default()),
            analysis_wake: parking_lot::Condvar::new(),
            analysis_state: Mutex::new(analysis::State::default()),
            analysis_write: Mutex::new(()),
            lists: Mutex::new(VecDeque::with_capacity(LISTS)),
            settings: Mutex::new(settings),
            open_listen: Mutex::new(None),
            carried_listen: Mutex::new(None),
            device_id,
            pending: Mutex::new(None),
            memory_state: Mutex::new(memory::State::default()),
            #[cfg(target_os = "macos")]
            fswatch: OnceLock::new(),
        })
    }

    pub fn now(&self) -> watch::Receiver<NowState> {
        self.now.subscribe()
    }

    /// Cover reads since this core started, including the initial rescan.
    pub fn cover_report(&self) -> meret_library::CoverReport {
        *self.cover_report.lock()
    }

    pub fn status(&self) -> watch::Receiver<StatusState> {
        self.status.subscribe()
    }

    /// Every engine event, in order: Started, Ended, anchors, errors.
    pub fn events(&self) -> broadcast::Receiver<EngineEvent> {
        self.events.subscribe()
    }

    /// Adds a folder to the library and scans it in the background.
    pub fn add_root(&self, path: &Path) -> Result<RootId> {
        let root = meret_library::add_root(&self.store, path)?;
        let _ = self.scans.send(ScanRequest::Root(root));
        self.roots_changed();
        Ok(root)
    }

    pub fn settings(&self) -> Settings {
        self.settings.lock().clone()
    }

    /// Persists settings. While playing, output changes wait for the next track;
    /// when paused they take effect on resume, and when idle on the next play.
    pub fn set_settings(&self, settings: Settings) -> Result<()> {
        let mut current = self.settings.lock();
        let level_changed = current.level != settings.level;
        let mut player = level_changed.then(|| self.player.lock());
        let gains = player.as_ref().map(|player| player.queue().items.iter().map(|item| {
            item.track.map_or(Ok(0.0), |track| level::queue_gain(&self.store, track, settings.level))
        }).collect::<meret_store::Result<Vec<_>>>()).transpose()?;
        self.store.set_settings(settings.clone())?;
        if current.output_device != settings.output_device || current.exclusive != settings.exclusive {
            self.engine.send(meret_engine::Control::SetOutput {
                device: settings.output_device.clone(), exclusive: settings.exclusive,
            });
        }
        let asked = current.lookups != settings.lookups;
        *current = settings;
        if let Some(player) = player.as_mut() {
            let mut gains = gains.expect("level changed").into_iter();
            player.refresh_gains(|_| gains.next().expect("one gain per queued item"));
        }
        drop(player);
        drop(current);
        if asked {
            lookups::seed(self);
            lookups::wake(self);
            lookups::publish(self);
        }
        Ok(())
    }

    pub fn output_devices(&self) -> Result<Vec<meret_engine::output::DeviceInfo>> {
        #[cfg(target_os = "macos")]
        let backend = meret_engine::output::coreaudio::CoreAudioBackend;
        #[cfg(not(target_os = "macos"))]
        return Err(meret_engine::output::OutputError::Unimplemented("output device enumeration").into());
        #[cfg(target_os = "macos")]
        Ok(backend.devices()?)
    }

    /// Play on (plate 09): every zone, saying what it does to the sound. For
    /// now the zones are this machine's output devices, judged from the
    /// settings without opening them. `current` is the device a session is
    /// playing on, else the chosen one; while that is absent, the system
    /// default that would stand in for it.
    pub fn zones(&self) -> Result<Vec<ZoneRow>> {
        let settings = self.settings();
        let place = if cfg!(target_os = "macos") { "This Mac" } else { "This device" };
        let devices = self.output_devices()?;
        let present = |uid: Option<String>| uid.filter(|uid| devices.iter().any(|d| &d.id == uid));
        let current_uid = present(self.engine.output_device()).or_else(|| present(settings.output_device.clone()));
        Ok(devices.into_iter().map(|d| {
            let current = current_uid.as_deref().map_or(d.is_default, |id| id == d.id);
            let top = d.sample_rates.iter().copied().max().unwrap_or(0);
            let fidelity = if !settings.exclusive || !d.can_be_exclusive {
                ZoneFidelity::Shared
            } else if top > 0 && top < 176_400 {
                ZoneFidelity::RefusesAbove { hz: top }
            } else {
                ZoneFidelity::BitPerfect
            };
            ZoneRow {
                info: ZoneInfo {
                    id: format!("local:{}", d.id),
                    name: d.name,
                    detail: if d.is_default { format!("{place} · default output") } else { place.into() },
                    host: "local".into(),
                    fidelity,
                    decodes_here: true,
                },
                current,
            }
        }).collect())
    }

    /// Switches output to a zone from `zones`; applies as `set_settings` does.
    pub fn play_on(&self, zone: &str) -> Result<()> {
        let device = zone.strip_prefix("local:").ok_or_else(|| CoreError::Query(format!("no zone {zone}")))?;
        if !self.output_devices()?.iter().any(|d| d.id == device) {
            return Err(CoreError::Query(format!("no zone {zone}")));
        }
        let settings = Settings { output_device: Some(device.to_owned()), ..self.settings() };
        self.set_settings(settings)
    }

    pub fn volume(&self) -> Result<meret_engine::output::DeviceVolume> {
        Ok(self.engine.volume()?)
    }

    pub fn set_volume(&self, scalar: f32) -> Result<meret_engine::output::DeviceVolume> {
        self.local.command(ZoneCommand::Volume { scalar })?;
        self.volume()
    }

    /// One volume key press: up or down a step of 16, or of 64 when `fine`.
    pub fn step_volume(&self, up: bool, fine: bool) -> Result<meret_engine::output::DeviceVolume> {
        let volume = self.volume()?;
        let Some(scalar) = volume.scalar.filter(|_| volume.settable) else {
            return Err(meret_engine::output::OutputError::Refused("this device has no settable hardware volume".into()).into());
        };
        self.set_volume(meret_engine::output::stepped(scalar, up, fine))
    }

    pub fn set_mute(&self, muted: bool) -> Result<meret_engine::output::DeviceVolume> {
        self.local.command(ZoneCommand::Mute { muted })?;
        self.volume()
    }

    /// Budgeted disk discovery; protected locations are never walked.
    pub fn suggest_folders(&self) -> Vec<FolderSuggestion> {
        let roots = match meret_library::roots(&self.store) {
            Ok(roots) => roots.into_iter().map(|r| r.path).collect::<Vec<_>>(),
            Err(error) => {
                tracing::error!(%error, "could not list roots for folder suggestions");
                return Vec::new();
            }
        };
        suggestions::suggest(&roots)
    }

    /// Serialized behind scans so an in-flight scan cannot restore this root.
    /// Returns after the hot columns and library version have been updated.
    pub fn remove_root(&self, root: RootId) -> Result<()> {
        let (done, result) = crossbeam_channel::bounded(1);
        self.scans.send(ScanRequest::Remove(root, done)).map_err(|_| meret_store::StoreError::WriterGone)?;
        result.recv().map_err(|_| meret_store::StoreError::WriterGone)??;
        self.roots_changed();
        Ok(())
    }

    /// Points the FSEvents watcher, if one runs, at the current roots.
    fn roots_changed(&self) {
        #[cfg(target_os = "macos")]
        if let Some(watcher) = self.fswatch.get() {
            let _ = watcher.send(fswatch::Message::Roots);
        }
    }

    /// Rescans every root in the background.
    pub fn rescan(&self) {
        let _ = self.scans.send(ScanRequest::AllRoots);
    }

    /// Resolves once every scan and column load queued so far has finished.
    pub fn scans_settled(&self) -> tokio::sync::oneshot::Receiver<()> {
        let (done, settled) = tokio::sync::oneshot::channel();
        let _ = self.scans.send(ScanRequest::Settled(done));
        settled
    }

    /// Where covers are written, at every size in `meret_store::COVER_SIZES`.
    pub fn art_dir(&self) -> PathBuf {
        self.config.data_dir.join("art")
    }

    /// What's queued, in order.
    pub fn queue(&self) -> Vec<QueueItem> {
        if let Some(saved) = &*self.pending.lock() {
            return saved.items.clone();
        }
        self.player.lock().queue().items.clone()
    }

    /// The queue after the playing item, up to `limit` items, and how many
    /// follow in all.
    pub fn up_next(&self, limit: usize) -> (Vec<QueueItem>, usize) {
        if let Some(saved) = &*self.pending.lock() {
            let rest = saved.items.get(saved.cursor + 1..).unwrap_or(&[]);
            return (rest.iter().take(limit).cloned().collect(), rest.len());
        }
        let player = self.player.lock();
        let rest = player.queue().up_next();
        (rest.iter().take(limit).cloned().collect(), rest.len())
    }

    /// What the query line shows as you type a search: the people and
    /// releases whose names have the typed words, and the result's tracks
    /// whose titles do: up to `names` people and releases, `tracks` tracks.
    pub fn search(&self, input: &str, names: usize, tracks: usize) -> Result<Search> {
        let q = match parse(input) {
            Ok(Input::Search(q)) => q,
            Ok(Input::Command(_)) => return Err(CoreError::Query("a command, not a search".into())),
            Err(e) => return Err(CoreError::Query(e.to_string())),
        };
        let query = q.to_string();
        let list = self.list(&query, &View::default())?;

        let mut words = vec![];
        let mut people = vec![];
        let mut releases = vec![];
        for c in q.clauses.iter().filter(|c| !c.negated) {
            match &c.term {
                Term::Text { text } => words.push(text.clone()),
                Term::Person { name, .. } => people.push(name.clone()),
                Term::Named { field: meret_query::NameField::Release, value } => releases.push(value.clone()),
                _ => {}
            }
        }
        people.splice(0..0, words.iter().cloned());
        releases.splice(0..0, words.iter().cloned());
        let (people_total, people) =
            if people.is_empty() { (0, vec![]) } else { self.store.people_hits(&people, names)? };
        let (releases_total, releases) =
            if releases.is_empty() { (0, vec![]) } else { self.store.release_hits(&releases, names)? };

        let titled = if words.is_empty() { None } else { Some(self.store.tracks_titled(&words)?) };
        let mut track_hits_total = 0;
        let mut picks: Vec<(usize, TrackId)> = vec![];
        for (i, &t) in list.tracks.iter().enumerate() {
            if titled.as_ref().is_none_or(|s| s.contains(&t)) {
                track_hits_total += 1;
                if picks.len() < tracks {
                    picks.push((i, t));
                }
            }
        }
        let ids: Vec<TrackId> = picks.iter().map(|&(_, t)| t).collect();
        let mut rows: std::collections::HashMap<TrackId, TrackRow> =
            self.store.track_rows(&ids)?.into_iter().map(|r| (r.track, r)).collect();
        let track_hits = picks.into_iter().filter_map(|(i, t)| Some((i, rows.remove(&t)?))).collect();

        Ok(Search {
            query,
            tracks: list.tracks.len(),
            people_total,
            people,
            releases_total,
            releases,
            track_hits,
            track_hits_total,
        })
    }

    /// What the Front shows about the library. Counts come from the hot
    /// columns; the rest is a few small reads, once per library change.
    pub fn front(&self) -> Result<Front> {
        static QUERIES: LazyLock<[Option<meret_query::Query>; 6]> = LazyLock::new(|| FRONT_FORMATS.map(|(_, _, query)| {
            query.map(|query| {
                let Input::Search(q) = parse(query).expect("valid Front format query") else {
                    panic!("Front format doors must be searches");
                };
                q
            })
        }));
        let (tracks, tracks_by_idiom, formats) = {
            let cols = self.columns.read();
            let formats = std::array::from_fn(|i| {
                let (label, note, query) = FRONT_FORMATS[i];
                let count = if let Some(parsed) = &QUERIES[i] {
                    // Format predicates are timeless and entirely column-backed.
                    let planned = meret_store::plan(parsed, &cols, 0);
                    assert!(planned.residual.is_empty(), "Front format doors must use hot columns");
                    planned.rows.expect("format queries have a bitmap").len()
                } else {
                    cols.format.iter().filter(|&&f| f == meret_store::format_code::UNKNOWN).count() as u64
                };
                FrontFormatLine { label, count, note, query }
            });
            (cols.len() as u64, cols.idiom_counts(&cols.all()), formats)
        };
        Ok(Front {
            tracks,
            tracks_by_idiom,
            formats,
            facts: self.store.library_facts(6)?,
            roots: meret_library::roots(&self.store)?,
        })
    }

    /// A release pane. None when the release doesn't exist. Opening one puts
    /// its lookup first in line, so its facts come while you look.
    pub fn release(&self, release: ReleaseId) -> Result<Option<ReleasePage>> {
        lookups::opened(self, meret_model::EntityKind::Release, release.0);
        Ok(self.store.release_page(release)?)
    }

    /// A person pane. None when the person doesn't exist.
    pub fn person(&self, agent: AgentId) -> Result<Option<PersonPage>> {
        lookups::opened(self, meret_model::EntityKind::Agent, agent.0);
        Ok(self.store.person_page(agent)?)
    }

    /// Plays a release's tracklist from row `index`, replacing the queue.
    pub fn play_release(&self, release: ReleaseId, index: usize) -> Result<()> {
        let page = self.store.release_page(release)?.ok_or_else(|| CoreError::Query("that release is gone".into()))?;
        self.play(queue_items(page.tracks.into_iter().skip(index)))
    }

    /// A work pane. None when the work doesn't exist.
    pub fn work(&self, work: WorkId) -> Result<Option<WorkPage>> {
        lookups::opened(self, meret_model::EntityKind::Work, work.0);
        Ok(self.store.work_page(work)?)
    }

    /// The MusicBrainz IDs the tags carry and what the lookups have done:
    /// the consent question's counts, and Settings › Lookups.
    pub fn lookup_summary(&self) -> Result<LookupSummary> {
        Ok(lookups::summary(self)?)
    }

    /// Queues recordings without current local analysis and wakes the workers.
    pub fn analyse(&self) -> Result<JobCounts> {
        analysis::seed(self)?;
        analysis::counts(self)
    }

    pub fn analysis_counts(&self) -> Result<JobCounts> {
        analysis::counts(self)
    }

    /// Plays a work's recordings from row `index`, replacing the queue.
    pub fn play_work(&self, work: WorkId, index: usize) -> Result<()> {
        let page = self.store.work_page(work)?.ok_or_else(|| CoreError::Query("that work is gone".into()))?;
        self.play(queue_items(page.tracks.into_iter().skip(index)))
    }

    /// A game pane. None when the game doesn't exist.
    pub fn game(&self, game: GameId) -> Result<Option<GamePage>> {
        Ok(self.store.game_page(game)?)
    }

    /// Plays a game's soundtracks from row `index`, replacing the queue.
    pub fn play_game(&self, game: GameId, index: usize) -> Result<()> {
        let page = self.store.game_page(game)?.ok_or_else(|| CoreError::Query("that game is gone".into()))?;
        self.play(queue_items(page.tracks.into_iter().skip(index)))
    }

    /// Plays a file directly, outside the library.
    pub fn play_file(&self, path: &Path) -> Result<()> {
        self.play(vec![QueueItem {
            token: 0,
            uri: file_uri(path),
            track: None,
            recording: None,
            release: None,
            work: None,
            idiom: Idiom::Album,
            from_stop: None,
            why: None,
            gain_db: 0.0,
        }])
    }

    fn play(&self, items: Vec<QueueItem>) -> Result<()> {
        self.play_at(items, 0, 0)
    }

    fn play_at(&self, mut items: Vec<QueueItem>, cursor: usize, start_ms: u64) -> Result<()> {
        let level = self.settings().level;
        for item in &mut items {
            item.gain_db = match item.track {
                Some(track) => level::queue_gain(&self.store, track, level)?,
                None => 0.0,
            };
        }
        self.memory_state.lock().stopping = false;
        let mut player = self.player.lock();
        let result = player.play(items, cursor, start_ms).map(|_| ());
        if let Some(error) = player.take_error() {
            self.now.send_modify(|n| n.error = Some(error));
        }
        result?;
        drop(player);
        self.pending.lock().take();
        Ok(())
    }

    pub fn pause(&self) {
        let _ = self.local.command(ZoneCommand::Pause);
    }

    pub fn resume(&self) -> Result<()> {
        if !self.play_pending(false)? {
            self.local.command(ZoneCommand::Resume)?;
        }
        Ok(())
    }

    pub fn from_start(&self) -> Result<()> {
        if !self.play_pending(true)? {
            self.local.command(ZoneCommand::Seek { ms: 0 })?;
        }
        Ok(())
    }

    fn play_pending(&self, from_start: bool) -> Result<bool> {
        let pending = self.pending.lock().take();
        let Some(saved) = pending else { return Ok(false) };
        let position = if from_start { 0 } else {
            meret_player::resume::resume_point(saved.items[saved.cursor].idiom, saved.position_ms, &[]).position_ms
        };
        // Picking up where the last run stopped is the same listen; from the
        // start is a new one.
        *self.carried_listen.lock() = saved.listen.zip(saved.items[saved.cursor].recording)
            .filter(|_| !from_start)
            .map(|(uid, recording)| listens::Carried { uid, recording });
        if let Err(error) = self.play_at(saved.items, saved.cursor, position) {
            self.carried_listen.lock().take();
            memory::restore(self)?;
            return Err(error);
        }
        Ok(true)
    }

    /// Writes the queue position and how far the open listen got. The app
    /// calls this as it quits; checkpoints cover a crash to within seconds.
    pub fn flush_memory(&self) {
        memory::flush(self);
    }

    pub fn resume_points(&self, limit: usize) -> Result<Vec<meret_store::ResumeRow>> {
        Ok(self.store.resume_points(limit)?)
    }

    pub fn pick_up(&self, release: ReleaseId) -> Result<()> {
        let (recording, saved_ms) = self.store.resume_for(release)?
            .ok_or_else(|| CoreError::Query("that release has no resume point".into()))?;
        let page = self.store.release_page(release)?.ok_or_else(|| CoreError::Query("that release is gone".into()))?;
        let at = page.tracks.iter().position(|row| row.recording == recording)
            .ok_or_else(|| CoreError::Query("the saved recording is unavailable".into()))?;
        let items = queue_items(page.tracks.into_iter().skip(at));
        let idiom = items.first().ok_or_else(|| CoreError::Query("the saved recording is unavailable".into()))?.idiom;
        let start_ms = meret_player::resume::resume_point(idiom, saved_ms, &[]).position_ms;
        self.play_at(items, 0, start_ms)
    }

    pub fn seek_ms(&self, ms: u64) {
        let _ = self.local.command(ZoneCommand::Seek { ms });
    }

    /// The next playable item in the queue; at its end, playback stops.
    pub fn next(&self) -> Result<()> {
        let mut player = self.player.lock();
        let result = player.skip_next().map(|_| ());
        if let Some(error) = player.take_error() {
            self.now.send_modify(|n| n.error = Some(error));
        }
        Ok(result?)
    }

    /// Restarts the playing item when it's more than `PREVIOUS_RESTART_MS`
    /// in, as every player does; otherwise the item before it.
    pub fn previous(&self) -> Result<()> {
        let mut player = self.player.lock();
        let playing = player.queue().current().map(|i| i.token);
        let position_ms = {
            let now = self.now.borrow();
            match now.anchor {
                Some(a) if Some(a.item) == playing => a.seconds_at(meret_engine::clock::now_ns()) * 1000.0,
                _ => 0.0,
            }
        };
        if position_ms > PREVIOUS_RESTART_MS as f64 {
            drop(player);
            self.seek_ms(0);
            return Ok(());
        }
        let result = player.skip_previous().map(|_| ());
        if let Some(error) = player.take_error() {
            self.now.send_modify(|n| n.error = Some(error));
        }
        Ok(result?)
    }

    pub fn stop(&self) {
        self.memory_state.lock().stopping = true;
        let _ = self.player.lock().stop();
    }
}

/// Rows with a present file, as queue items.
fn queue_items(rows: impl IntoIterator<Item = TrackRow>) -> Vec<QueueItem> {
    rows.into_iter()
        .filter_map(|r| {
            Some(QueueItem {
                token: 0,
                uri: file_uri(Path::new(r.path.as_deref()?)),
                track: Some(r.track),
                recording: Some(r.recording),
                release: Some(r.release),
                work: None,
                idiom: r.idiom.unwrap_or(Idiom::Album),
                from_stop: None,
                why: None,
                gain_db: 0.0,
            })
        })
        .collect()
}

fn now_s() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}
