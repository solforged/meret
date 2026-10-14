//! Zones: anything Meret can play to. The local engine, a Roon zone, a Music
//! Assistant player (Sonos, AirPlay, Chromecast), Spotify Connect, or another
//! Meret. Each says what it does to the sound (plate 09, "Play on").

use meret_model::signal::SignalPath;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ZoneFidelity {
    /// ● Samples reach the DAC unchanged.
    BitPerfect,
    /// ● Bit-perfect, through another system ("via Roon").
    BitPerfectVia { system: String },
    /// ◐ Resampled above a rate ("above 48 kHz resampled").
    ResampledAbove { hz: u32 },
    /// ◐ A fixed format plus delay (AirPlay: 16/44.1, about 2 s).
    Fixed { description: String, delay_ms: u32 },
    /// ○ Lossy by nature (Spotify Connect).
    Lossy,
    /// ○ Plays its own copy (a phone after hand-off).
    OwnCopy,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ZoneInfo {
    pub id: String,
    /// "This Mac", "Study", "Living room".
    pub name: String,
    /// "RME ADI-2 DAC · USB", "Roon Ready · Lumin", "Sonos via Music Assistant".
    pub detail: String,
    /// Which provider hosts it: "local", "roon", "music_assistant", "spotify".
    pub host: String,
    pub fidelity: ZoneFidelity,
    /// Whether Meret decodes for this zone (local, Roon Ready) or only
    /// controls it (Spotify Connect).
    pub decodes_here: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum ZoneCommand {
    Play { item: u64, uri: String, start_ms: u64 },
    SetNext { item: u64, uri: String },
    Pause,
    Resume,
    Seek { ms: u64 },
    Stop,
    Volume { db: f32 },
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ZoneState {
    pub item: Option<u64>,
    pub position_ms: u64,
    pub playing: bool,
    pub path: Option<SignalPath>,
    pub available: bool,
}

/// Implemented by the local engine and by every provider that hosts zones.
/// Commands are fire-and-forget; state comes back through `state`.
pub trait Zone: Send + Sync {
    fn info(&self) -> ZoneInfo;
    fn command(&self, cmd: ZoneCommand) -> Result<(), ZoneError>;
    fn state(&self) -> ZoneState;
}

#[derive(Debug, thiserror::Error)]
pub enum ZoneError {
    #[error("the zone is unavailable")]
    Unavailable,
    #[error("the zone can't play {0}")]
    CannotPlay(String),
    #[error("{0}")]
    Other(String),
}
