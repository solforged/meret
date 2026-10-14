//! Output backends.
//!
//! macOS talks to the CoreAudio HAL directly rather than through cpal, because
//! bit-perfect output needs hog mode, control of the nominal sample rate and
//! the physical stream format. Android uses AAudio, with Android 14's
//! bit-perfect mixer attributes for USB DACs set from Kotlin. WASAPI
//! (exclusive) and ALSA/PipeWire come later behind the same trait.

#[cfg(target_os = "macos")]
pub mod coreaudio;
pub mod null;

use std::sync::Arc;

use meret_model::audio::StreamSpec;

use crate::clock::SharedClock;
use crate::ring::RingReader;

#[derive(Debug, thiserror::Error)]
pub enum OutputError {
    #[error("no such device: {0}")]
    NoDevice(String),
    #[error("the device refused {0}")]
    Refused(String),
    #[error("not built yet: {0}")]
    Unimplemented(&'static str),
    #[error("{0}")]
    Platform(String),
}

#[derive(Clone, Debug)]
pub struct DeviceInfo {
    pub id: String,
    /// "RME ADI-2 DAC", "MacBook Pro Speakers".
    pub name: String,
    pub sample_rates: Vec<u32>,
    pub max_bits: u8,
    pub can_be_exclusive: bool,
    pub dop: bool,
}

#[derive(Clone, Debug)]
pub struct OutputRequest {
    /// `None` for the system default.
    pub device: Option<String>,
    pub spec: StreamSpec,
    /// Take the device for ourselves (hog mode, AAudio exclusive).
    pub exclusive: bool,
}

/// What the device actually agreed to. The signal path is built from this.
#[derive(Clone, Debug, PartialEq)]
pub struct Opened {
    pub device_name: String,
    pub sample_rate: u32,
    pub bits: u8,
    pub channels: u16,
    pub exclusive: bool,
    /// Frames between the ring and the speaker, for lining up the clock.
    pub latency_frames: u32,
}

pub trait OutputBackend: Send + Sync {
    fn name(&self) -> &'static str;
    fn devices(&self) -> Result<Vec<DeviceInfo>, OutputError>;
    /// Opens a stream that pulls from `source` and advances `clock`.
    /// The returned stream owns the realtime callback.
    fn open(
        &self,
        req: &OutputRequest,
        source: RingReader,
        clock: Arc<SharedClock>,
    ) -> Result<Box<dyn OutputStream>, OutputError>;
}

pub trait OutputStream: Send {
    fn opened(&self) -> &Opened;
    fn start(&mut self) -> Result<(), OutputError>;
    fn pause(&mut self) -> Result<(), OutputError>;
}
