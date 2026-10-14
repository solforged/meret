//! The runtime: one per process, started by the platform host (the macOS app
//! delegate, Android's MediaSessionService) before any UI exists, so playback
//! never depends on a window. The UI attaches through `meret-api`.

mod local_zone;
mod now;
mod scan;
mod status;

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use crossbeam_channel::Sender;
use meret_engine::engine::EngineConfig;
use meret_engine::output::OutputBackend;
use meret_engine::output::null::NullBackend;
use meret_engine::{Engine, EngineEvent};
use meret_graph::Trail;
use meret_jobs::Scheduler;
use meret_model::{AgentId, Idiom, ReleaseId, RootId, TrackId};
use meret_player::{Player, QueueItem, Zone, ZoneCommand, ZoneError};
use meret_provider::Registry;
use meret_query::{Input, Term, parse};
use meret_store::{HotColumns, LibraryFacts, PersonHit, ReleaseHit, Store, TrackRow, plan};
pub use meret_store::{Colleague, PersonPage, PersonRelease, ReleasePage, TrackCredit};
use parking_lot::{Mutex, RwLock};
use tokio::sync::{broadcast, watch};

pub use local_zone::{LocalZone, file_uri};
pub use now::NowState;
pub use status::{SourceStatus, StatusState};

use scan::ScanRequest;

/// How many results "play these" queues, from the row it starts at.
pub const MAX_QUEUE: usize = 10_000;

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
    /// Indexed by `meret_store::format_code`.
    pub tracks_by_format: [u64; 6],
    pub facts: LibraryFacts,
    pub roots: Vec<meret_library::Root>,
}

/// A query's result, held by the core so the UI can page through it.
/// Tracks, not row numbers, so it survives the columns being reloaded.
pub struct List {
    pub query: String,
    pub version: u64,
    /// Unix seconds when it was planned; `last:` and `added:` move with time.
    pub made_s: i64,
    pub tracks: Vec<TrackId>,
}

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
    pub trail: Mutex<Option<Trail>>,
    pub engine: Arc<Engine>,
    pub local: Arc<LocalZone>,
    pub player: Mutex<Player>,
    pub runtime: tokio::runtime::Runtime,
    now: watch::Sender<NowState>,
    status: watch::Sender<StatusState>,
    events: broadcast::Sender<EngineEvent>,
    scans: Sender<ScanRequest>,
    lists: Mutex<VecDeque<Arc<List>>>,
}

static CORE: OnceLock<Arc<Core>> = OnceLock::new();

/// Starts the process-wide core, or returns the running one. The hot
/// columns load and known roots rescan in the background.
pub fn start(config: CoreConfig) -> Result<Arc<Core>> {
    if let Some(c) = CORE.get() {
        return if c.config.data_dir == config.data_dir { Ok(c.clone()) } else { Err(CoreError::AlreadyStarted) };
    }
    let (scans, requests) = crossbeam_channel::unbounded();
    let core = Arc::new(Core::new(config, scans)?);
    let core = CORE.get_or_init(|| core).clone();
    now::spawn_pump(core.clone());
    scan::spawn_worker(core.clone(), requests);
    let _ = core.scans.send(ScanRequest::LoadColumns);
    let _ = core.scans.send(ScanRequest::AllRoots);
    Ok(core)
}

pub fn get() -> Option<Arc<Core>> {
    CORE.get().cloned()
}

impl Core {
    fn new(config: CoreConfig, scans: Sender<ScanRequest>) -> Result<Self> {
        std::fs::create_dir_all(&config.data_dir)?;
        let store = Store::open(&config.data_dir.join("library.db"))?;

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
            .build()?;

        let status = status::initial(&registry);
        Ok(Self {
            config,
            store,
            columns,
            registry,
            scheduler: Mutex::new(Scheduler::default()),
            trail: Mutex::new(None),
            engine,
            player: Mutex::new(Player::new(local.clone())),
            local,
            runtime,
            now: watch::channel(NowState::default()).0,
            status: watch::channel(status).0,
            events: broadcast::channel(256).0,
            scans,
            lists: Mutex::new(VecDeque::with_capacity(LISTS)),
        })
    }

    pub fn now(&self) -> watch::Receiver<NowState> {
        self.now.subscribe()
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
        Ok(root)
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

    /// What's queued, in order.
    pub fn queue(&self) -> Vec<QueueItem> {
        self.player.lock().queue().items.clone()
    }

    /// The tracks matching `query`, in library order. The latest few lists
    /// are kept until the library changes, or for a minute, so paging is
    /// cheap and relative times still move.
    ///
    /// The hot columns answer what they can; text, people and release names
    /// go to full-text search.
    pub fn list(&self, query: &str) -> Result<Arc<List>> {
        let version = self.status.borrow().library_version;
        let now = now_s();
        {
            let mut cached = self.lists.lock();
            cached.retain(|l| l.version == version && now - l.made_s < LIST_TTL_S);
            if let Some(i) = cached.iter().position(|l| l.query == query) {
                let l = cached.remove(i).expect("found");
                cached.push_front(l.clone());
                return Ok(l);
            }
        }
        // Planned without the cache locked, so a slow search being typed
        // doesn't hold up a table paging through another list.
        let cols = self.columns.read();
        let rows = if query.trim().is_empty() {
            None
        } else {
            match parse(query) {
                Ok(Input::Search(q)) => self.store.answer_residual(plan(&q, &cols, now), &cols)?,
                Ok(Input::Command(_)) => return Err(CoreError::Query("a command, not a search".into())),
                Err(e) => return Err(CoreError::Query(e.to_string())),
            }
        };
        let tracks = match rows {
            Some(r) => r.iter().map(|i| cols.track[i as usize]).collect(),
            None => cols.track.clone(),
        };
        let list = Arc::new(List { query: query.into(), version, made_s: now, tracks });
        let mut cached = self.lists.lock();
        cached.retain(|l| l.query != query);
        cached.truncate(LISTS - 1);
        cached.push_front(list.clone());
        Ok(list)
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
        let list = self.list(&query)?;

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

    /// Rows `offset..offset + limit` of `query`'s result, and its total.
    pub fn rows(&self, query: &str, offset: usize, limit: usize) -> Result<(usize, Vec<TrackRow>)> {
        let list = self.list(query)?;
        let page = list.tracks.get(offset.min(list.tracks.len())..(offset + limit).min(list.tracks.len()));
        Ok((list.tracks.len(), self.store.track_rows(page.unwrap_or(&[]))?))
    }

    /// What the Front shows about the library. Counts come from the hot
    /// columns; the rest is a few small reads, once per library change.
    pub fn front(&self) -> Result<Front> {
        let (tracks, tracks_by_idiom, tracks_by_format) = {
            let cols = self.columns.read();
            let mut by_format = [0u64; 6];
            for &f in &cols.format {
                if let Some(n) = by_format.get_mut(f as usize) {
                    *n += 1;
                }
            }
            (cols.len() as u64, cols.idiom_counts(&cols.all()), by_format)
        };
        Ok(Front {
            tracks,
            tracks_by_idiom,
            tracks_by_format,
            facts: self.store.library_facts(6)?,
            roots: meret_library::roots(&self.store)?,
        })
    }

    /// Plays `query`'s result from row `index`, replacing the queue. Up to
    /// `MAX_QUEUE` rows are queued.
    pub fn play_results(&self, query: &str, index: usize) -> Result<()> {
        let list = self.list(query)?;
        let end = (index + MAX_QUEUE).min(list.tracks.len());
        let rows = self.store.track_rows(list.tracks.get(index..end).unwrap_or(&[]))?;
        self.play(queue_items(rows))
    }

    /// A release pane. None when the release doesn't exist.
    pub fn release(&self, release: ReleaseId) -> Result<Option<ReleasePage>> {
        Ok(self.store.release_page(release)?)
    }

    /// A person pane. None when the person doesn't exist.
    pub fn person(&self, agent: AgentId) -> Result<Option<PersonPage>> {
        Ok(self.store.person_page(agent)?)
    }

    /// Plays a release's tracklist from row `index`, replacing the queue.
    pub fn play_release(&self, release: ReleaseId, index: usize) -> Result<()> {
        let page = self.store.release_page(release)?.ok_or_else(|| CoreError::Query("that release is gone".into()))?;
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
        }])
    }

    fn play(&self, items: Vec<QueueItem>) -> Result<()> {
        let mut player = self.player.lock();
        let result = player.play(items, 0).map(|_| ());
        if let Some(error) = player.take_error() {
            self.now.send_modify(|n| n.error = Some(error));
        }
        result?;
        Ok(())
    }

    pub fn pause(&self) {
        let _ = self.local.command(ZoneCommand::Pause);
    }

    pub fn resume(&self) {
        let _ = self.local.command(ZoneCommand::Resume);
    }

    pub fn seek_ms(&self, ms: u64) {
        let _ = self.local.command(ZoneCommand::Seek { ms });
    }

    pub fn stop(&self) {
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
            })
        })
        .collect()
}

fn now_s() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}
