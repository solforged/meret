//! The playback clock.
//!
//! The audio callback writes how many frames it has handed the device and
//! when. A publisher outside the callback turns that into an `Anchor`, sent
//! only when something changes. The UI extrapolates from the anchor every
//! vsync, so a 120 Hz playhead costs no traffic at all.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

/// Nanoseconds on a monotonic clock shared by the whole process.
pub fn now_ns() -> u64 {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    EPOCH.get_or_init(Instant::now).elapsed().as_nanos() as u64
}

/// Written by the audio callback, read by the publisher.
#[derive(Default)]
pub struct SharedClock {
    frames: AtomicU64,
    at_ns: AtomicU64,
    playing: AtomicBool,
    underruns: AtomicU64,
    flush_requested: AtomicU64,
    flush_done: AtomicU64,
}

impl SharedClock {
    /// Called from the callback after handing `frames` more frames to the device.
    #[inline]
    pub fn advance(&self, frames: u64, at_ns: u64) {
        self.frames.fetch_add(frames, Ordering::Relaxed);
        self.at_ns.store(at_ns, Ordering::Release);
    }

    #[inline]
    pub fn underrun(&self) {
        self.underruns.fetch_add(1, Ordering::Relaxed);
    }

    pub fn set_playing(&self, playing: bool) {
        self.playing.store(playing, Ordering::Release);
    }

    /// Frames handed to the device since the stream opened, and when.
    pub fn read(&self) -> (u64, u64, bool) {
        let at = self.at_ns.load(Ordering::Acquire);
        (self.frames.load(Ordering::Relaxed), at, self.playing.load(Ordering::Acquire))
    }

    pub fn underruns(&self) -> u64 {
        self.underruns.load(Ordering::Relaxed)
    }

    /// Asks the callback to drop everything buffered (a seek, a skip).
    /// Returns a generation to wait on with `flushed`.
    pub fn request_flush(&self) -> u64 {
        self.flush_requested.fetch_add(1, Ordering::AcqRel) + 1
    }

    /// Whether a flush has been asked for and the callback hasn't done it yet.
    pub fn flush_outstanding(&self) -> bool {
        self.flush_requested.load(Ordering::Acquire) > self.flush_done.load(Ordering::Acquire)
    }

    pub fn flushed(&self, generation: u64) -> bool {
        self.flush_done.load(Ordering::Acquire) >= generation
    }

    /// Called from the callback before reading. Returns true if it should
    /// clear the ring now; it must then call `ack_flush`. Realtime-safe.
    #[inline]
    pub fn flush_pending(&self) -> Option<u64> {
        let req = self.flush_requested.load(Ordering::Acquire);
        (req > self.flush_done.load(Ordering::Relaxed)).then_some(req)
    }

    #[inline]
    pub fn ack_flush(&self, generation: u64) {
        self.flush_done.store(generation, Ordering::Release);
    }

    pub fn reset(&self) {
        self.frames.store(0, Ordering::Relaxed);
        self.at_ns.store(now_ns(), Ordering::Release);
    }
}

/// Where playback was at a moment, and how fast it's moving.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Anchor {
    /// Which queue item this position is in.
    pub item: u64,
    pub position_frames: u64,
    pub sample_rate: u32,
    /// `now_ns()` at which `position_frames` was true.
    pub at_ns: u64,
    /// 1.0 normally; 0.0 when paused.
    pub rate: f64,
}

impl Anchor {
    /// `at_ns` can be slightly in the future: a device reports when the frames
    /// it was just handed will reach the speaker.
    pub fn seconds_at(&self, now_ns: u64) -> f64 {
        let base = self.position_frames as f64 / self.sample_rate as f64;
        let dt = (now_ns as i128 - self.at_ns as i128) as f64 / 1e9;
        (base + self.rate * dt).max(0.0)
    }

    /// Whether `next` says something the UI couldn't have extrapolated:
    /// a different item, a change of rate, or drift over `tolerance_ms`.
    pub fn differs(&self, next: &Anchor, tolerance_ms: f64) -> bool {
        if self.item != next.item || self.rate != next.rate || self.sample_rate != next.sample_rate {
            return true;
        }
        (self.seconds_at(next.at_ns) - next.seconds_at(next.at_ns)).abs() * 1000.0 > tolerance_ms
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(pos: u64, at_ms: u64, rate: f64) -> Anchor {
        Anchor { item: 1, position_frames: pos, sample_rate: 44_100, at_ns: at_ms * 1_000_000, rate }
    }

    #[test]
    fn extrapolates_while_playing_and_holds_while_paused() {
        let playing = a(44_100, 1_000, 1.0);
        assert!((playing.seconds_at(1_500_000_000) - 1.5).abs() < 1e-9);
        let paused = a(44_100, 1_000, 0.0);
        assert!((paused.seconds_at(9_000_000_000) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn republishes_only_on_drift_or_change() {
        let first = a(0, 0, 1.0);
        // Exactly where extrapolation said: nothing to send.
        assert!(!first.differs(&a(44_100, 1_000, 1.0), 2.0));
        // 5 ms behind: send.
        assert!(first.differs(&a(44_100 - 220, 1_000, 1.0), 2.0));
        // Paused: send.
        assert!(first.differs(&a(44_100, 1_000, 0.0), 2.0));
    }
}
