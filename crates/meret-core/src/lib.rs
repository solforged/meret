//! The runtime: one per process, started by the platform host (the macOS app
//! delegate, Android's MediaSessionService) before any UI exists, so playback
//! never depends on a window. The UI attaches through `meret-api`.

mod local_zone;
mod now;
mod status;

use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use meret_engine::engine::EngineConfig;
use meret_engine::output::OutputBackend;
use meret_engine::output::null::NullBackend;
use meret_engine::{Control, Engine, Load, decode};
use meret_graph::Trail;
use meret_jobs::Scheduler;
use meret_provider::Registry;
use meret_store::{HotColumns, Store};
use parking_lot::{Mutex, RwLock};
use tokio::sync::watch;

pub use now::NowState;
pub use status::{SourceStatus, StatusState};

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error(transparent)]
    Store(#[from] meret_store::StoreError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Decode(#[from] meret_engine::DecodeError),
    #[error("the core is already running with a different data directory")]
    AlreadyStarted,
}

pub type Result<T> = std::result::Result<T, CoreError>;

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

pub struct Core {
    pub config: CoreConfig,
    pub store: Store,
    pub columns: RwLock<HotColumns>,
    pub registry: Registry,
    pub scheduler: Mutex<Scheduler>,
    pub trail: Mutex<Option<Trail>>,
    pub engine: Engine,
    pub runtime: tokio::runtime::Runtime,
    now: watch::Sender<NowState>,
    status: watch::Sender<StatusState>,
}

static CORE: OnceLock<Arc<Core>> = OnceLock::new();

/// Starts the process-wide core, or returns the running one.
pub fn start(config: CoreConfig) -> Result<Arc<Core>> {
    if let Some(c) = CORE.get() {
        return if c.config.data_dir == config.data_dir { Ok(c.clone()) } else { Err(CoreError::AlreadyStarted) };
    }
    let core = Arc::new(Core::new(config)?);
    let core = CORE.get_or_init(|| core).clone();
    now::spawn_pump(core.clone());
    Ok(core)
}

pub fn get() -> Option<Arc<Core>> {
    CORE.get().cloned()
}

impl Core {
    fn new(config: CoreConfig) -> Result<Self> {
        std::fs::create_dir_all(&config.data_dir)?;
        let store = Store::open(&config.data_dir.join("library.db"))?;

        // TODO(core): load hot columns from a snapshot file, then from SQLite.
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
        let engine = Engine::spawn(backend, engine_config);

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
            runtime,
            now: watch::channel(NowState::default()).0,
            status: watch::channel(status).0,
        })
    }

    pub fn now(&self) -> watch::Receiver<NowState> {
        self.now.subscribe()
    }

    pub fn status(&self) -> watch::Receiver<StatusState> {
        self.status.subscribe()
    }

    /// Plays a file directly, outside the library. The queue and idiom rules
    /// arrive with the library; this is enough to drive the engine and Now.
    pub fn play_file(&self, path: &Path) -> Result<()> {
        let decoder = decode::open(path)?;
        let title = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        self.now.send_modify(|n| {
            n.title = title;
            n.subtitle = path.parent().map(|p| p.display().to_string()).unwrap_or_default();
            n.item = Some(1);
        });
        self.engine.send(Control::Play(Load { item: 1, decoder, start_frame: 0, stages: vec![] }));
        Ok(())
    }

    pub fn pause(&self) {
        self.engine.send(Control::Pause);
    }

    pub fn resume(&self) {
        self.engine.send(Control::Resume);
    }

    pub fn seek_ms(&self, ms: u64) {
        let rate = self.now.borrow().anchor.map(|a| a.sample_rate).unwrap_or(44_100);
        self.engine.send(Control::Seek(ms * rate as u64 / 1000));
    }

    pub fn stop(&self) {
        self.engine.send(Control::Stop);
    }
}
