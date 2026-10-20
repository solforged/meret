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
    pub is_default: bool,
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
    pub device_uid: String,
    pub device_name: String,
    pub sample_rate: u32,
    pub bits: u8,
    pub channels: u16,
    pub exclusive: bool,
    /// Frames between the ring and the speaker, for lining up the clock.
    pub latency_frames: u32,
}

/// Hardware volume only. Samples in the ring are never scaled.
#[derive(Clone, Debug, PartialEq)]
pub struct DeviceVolume {
    pub scalar: Option<f32>,
    pub settable: bool,
    pub reason: Option<String>,
}

impl DeviceVolume {
    pub fn unsupported(reason: impl Into<String>) -> Self {
        Self { scalar: None, settable: false, reason: Some(reason.into()) }
    }
}

/// Device settings contain stable UIDs, never user-visible names.
pub fn device_uid(devices: &[DeviceInfo], wanted: Option<&str>) -> Result<String, OutputError> {
    devices.iter()
        .find(|d| wanted.map_or(d.is_default, |uid| d.id == uid))
        .map(|d| d.id.clone())
        .ok_or_else(|| OutputError::NoDevice(wanted.unwrap_or("system default").into()))
}

pub trait OutputBackend: Send + Sync {
    fn name(&self) -> &'static str;
    fn devices(&self) -> Result<Vec<DeviceInfo>, OutputError>;
    fn resolve_device(&self, wanted: Option<&str>) -> Result<String, OutputError> {
        device_uid(&self.devices()?, wanted)
    }
    fn volume(&self, _device: Option<&str>) -> Result<DeviceVolume, OutputError> {
        Ok(DeviceVolume::unsupported("No volume control on this output"))
    }
    fn set_volume(&self, _device: Option<&str>, _scalar: f32) -> Result<DeviceVolume, OutputError> {
        Err(OutputError::Refused("device volume is not available on this output".into()))
    }
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
    /// The device went away (unplugged, disconnected) and won't play again.
    fn lost(&self) -> bool {
        false
    }
    /// Stops and closes the device, returning its unread ring without copying.
    /// Used to change outputs while paused without losing buffered joins.
    fn into_source(self: Box<Self>) -> RingReader;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_selection_accepts_uids_not_names() {
        let devices = vec![
            DeviceInfo { id: "uid-a".into(), name: "Speakers".into(), is_default: true,
                sample_rates: vec![], max_bits: 24, can_be_exclusive: true, dop: false },
            DeviceInfo { id: "uid-b".into(), name: "Speakers".into(), is_default: false,
                sample_rates: vec![], max_bits: 24, can_be_exclusive: true, dop: false },
        ];
        assert_eq!(device_uid(&devices, None).unwrap(), "uid-a");
        assert_eq!(device_uid(&devices, Some("uid-b")).unwrap(), "uid-b");
        assert!(device_uid(&devices, Some("Speakers")).is_err());
        assert!(device_uid(&[], None).is_err());
    }
}
