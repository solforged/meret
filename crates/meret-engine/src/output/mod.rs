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
    /// The UID of the device this is the volume of.
    pub device: Option<String>,
    pub scalar: Option<f32>,
    pub settable: bool,
    /// None when the device has no mute of its own.
    pub muted: Option<bool>,
    pub reason: Option<String>,
}

impl DeviceVolume {
    pub fn unsupported(reason: impl Into<String>) -> Self {
        Self { device: None, scalar: None, settable: false, muted: None, reason: Some(reason.into()) }
    }
}

/// Steps a volume the way macOS's volume keys do: sixteen steps, or 64
/// when `fine`, snapped to the grid so a device that stores the scalar
/// coarsely (0.24 reads back as 0.2383) still moves every press.
pub fn stepped(scalar: f32, up: bool, fine: bool) -> f32 {
    let steps = if fine { 64.0 } else { 16.0 };
    let at = (scalar.clamp(0.0, 1.0) * steps).round();
    ((if up { at + 1.0 } else { at - 1.0 }) / steps).clamp(0.0, 1.0)
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
    fn set_mute(&self, _device: Option<&str>, _muted: bool) -> Result<DeviceVolume, OutputError> {
        Err(OutputError::Refused("mute is not available on this output".into()))
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

    #[test]
    fn volume_steps_snap_to_the_key_grid_and_stop_at_the_ends() {
        assert_eq!(stepped(0.5, true, false), 0.5625);
        assert_eq!(stepped(0.5, false, true), 0.484375);
        // The Studio Display stores 0.25 as 0.2383; the next press still moves.
        assert_eq!(stepped(0.2383, true, false), 0.3125);
        assert_eq!(stepped(0.2383, false, false), 0.1875);
        assert_eq!(stepped(0.31, true, false), 0.375);
        assert_eq!(stepped(1.0, true, false), 1.0);
        assert_eq!(stepped(0.01, false, false), 0.0);
        assert_eq!(stepped(0.0, false, true), 0.0);
    }
}
