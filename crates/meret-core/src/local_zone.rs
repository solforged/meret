//! The local engine as a `Zone`, so the player treats This Mac like any room.
//!
//! Commands open a decoder for the item's file and hand it to the engine;
//! opening happens on the caller's thread, never the engine's. State follows
//! the engine's events, which the core's pump passes to `observe`.

use std::path::Path;
use std::sync::Arc;

use meret_engine::{Control, Engine, EngineEvent, Load, decode};
use meret_model::signal::Fidelity;
use meret_player::{Zone, ZoneCommand, ZoneError, ZoneFidelity, ZoneInfo, ZoneState};
use parking_lot::Mutex;

pub struct LocalZone {
    engine: Arc<Engine>,
    state: Mutex<Local>,
}

#[derive(Default)]
struct Local {
    zone: ZoneState,
    sample_rate: Option<u32>,
}

/// The URI a local file plays by. Paths are not percent-encoded.
pub fn file_uri(path: &Path) -> String {
    format!("file://{}", path.display())
}

impl LocalZone {
    pub fn new(engine: Arc<Engine>) -> Self {
        let zone = ZoneState { available: true, ..Default::default() };
        Self { engine, state: Mutex::new(Local { zone, sample_rate: None }) }
    }

    pub fn observe(&self, e: &EngineEvent) {
        let mut s = self.state.lock();
        match e {
            EngineEvent::Started { item, path } => {
                s.zone.item = Some(*item);
                s.zone.path = Some(path.clone());
                s.zone.playing = true;
            }
            EngineEvent::OutputChanged { path } => s.zone.path = Some(path.clone()),
            EngineEvent::Anchor(a) => {
                s.zone.position_ms = a.position_frames * 1000 / a.sample_rate.max(1) as u64;
                s.zone.playing = a.rate > 0.0;
                s.sample_rate = Some(a.sample_rate);
            }
            EngineEvent::Idle => s.zone.playing = false,
            EngineEvent::Ended { .. } | EngineEvent::Error { .. } | EngineEvent::VolumeChanged => {}
        }
    }

    fn load(item: u64, uri: &str, start_ms: u64, gain_db: f64) -> Result<Load, ZoneError> {
        let path = uri.strip_prefix("file://").ok_or_else(|| ZoneError::CannotPlay(uri.into()))?;
        let decoder = decode::open(Path::new(path)).map_err(|e| ZoneError::CannotPlay(format!("{path}: {e}")))?;
        let start_frame = start_ms * decoder.spec().sample_rate as u64 / 1000;
        Ok(Load { item, decoder, start_frame, gain_db, stages: vec![] })
    }
}

impl Zone for LocalZone {
    fn info(&self) -> ZoneInfo {
        let s = self.state.lock();
        let out = s.zone.path.as_ref().and_then(|p| p.stages.last()).map(|o| o.detail.clone());
        let fidelity = match s.zone.path.as_ref().map(|p| p.fidelity()) {
            None | Some(Fidelity::BitPerfect) => ZoneFidelity::BitPerfect,
            Some(Fidelity::Lossy) => ZoneFidelity::Lossy,
            Some(Fidelity::Altered) => {
                ZoneFidelity::Fixed { description: out.clone().unwrap_or_default(), delay_ms: 0 }
            }
        };
        ZoneInfo {
            id: "local".into(),
            name: if cfg!(target_os = "macos") { "This Mac" } else { "This device" }.into(),
            detail: out.unwrap_or_default(),
            host: "local".into(),
            fidelity,
            decodes_here: true,
        }
    }

    fn command(&self, cmd: ZoneCommand) -> Result<(), ZoneError> {
        let control = match cmd {
            ZoneCommand::Play { item, uri, start_ms, gain_db } => Control::Play(Self::load(item, &uri, start_ms, gain_db)?),
            ZoneCommand::SetNext { item, uri, gain_db } => Control::SetNext(Some(Self::load(item, &uri, 0, gain_db)?)),
            ZoneCommand::Pause => Control::Pause,
            ZoneCommand::Resume => Control::Resume,
            ZoneCommand::Seek { ms } => {
                let rate = self.state.lock().sample_rate.unwrap_or(44_100);
                Control::Seek(ms * rate as u64 / 1000)
            }
            ZoneCommand::Stop => Control::Stop,
            ZoneCommand::Volume { scalar } => {
                self.engine.set_volume(scalar).map_err(|e| ZoneError::Other(e.to_string()))?;
                return Ok(());
            }
        };
        self.engine.send(control);
        Ok(())
    }

    fn state(&self) -> ZoneState {
        self.state.lock().zone.clone()
    }
}
