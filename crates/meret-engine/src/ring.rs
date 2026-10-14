//! The ring between the decode thread and the audio callback.
//! A thin wrapper over `rtrb` that moves whole slices and never allocates.

use rtrb::{Consumer, Producer, RingBuffer};

use crate::Sample;

pub struct RingWriter {
    inner: Producer<Sample>,
    channels: usize,
}

pub struct RingReader {
    inner: Consumer<Sample>,
    channels: usize,
}

/// A ring holding `frames` frames of `channels` channels.
pub fn ring(frames: usize, channels: u16) -> (RingWriter, RingReader) {
    let channels = channels as usize;
    let (p, c) = RingBuffer::new(frames * channels);
    (RingWriter { inner: p, channels }, RingReader { inner: c, channels })
}

impl RingWriter {
    /// Whole frames that can be written now.
    pub fn free_frames(&self) -> usize {
        self.inner.slots() / self.channels
    }

    /// Writes as many whole frames from `data` as fit. Returns frames written.
    pub fn write(&mut self, data: &[Sample]) -> usize {
        let frames = (data.len() / self.channels).min(self.free_frames());
        let n = frames * self.channels;
        if n == 0 {
            return 0;
        }
        let mut chunk = self.inner.write_chunk(n).expect("checked free space");
        let (a, b) = chunk.as_mut_slices();
        a.copy_from_slice(&data[..a.len()]);
        b.copy_from_slice(&data[a.len()..n]);
        chunk.commit_all();
        frames
    }

    pub fn is_abandoned(&self) -> bool {
        self.inner.is_abandoned()
    }
}

impl RingReader {
    pub fn channels(&self) -> usize {
        self.channels
    }

    pub fn available_frames(&self) -> usize {
        self.inner.slots() / self.channels
    }

    /// Fills `out` with as many whole frames as are available and zero-fills
    /// the rest. Returns frames read; anything short of `out` is an underrun.
    /// Realtime-safe.
    pub fn read(&mut self, out: &mut [Sample]) -> usize {
        let want = out.len() / self.channels;
        let frames = want.min(self.available_frames());
        let n = frames * self.channels;
        if n > 0 {
            let chunk = self.inner.read_chunk(n).expect("checked availability");
            let (a, b) = chunk.as_slices();
            out[..a.len()].copy_from_slice(a);
            out[a.len()..n].copy_from_slice(b);
            chunk.commit_all();
        }
        out[n..].fill(0);
        frames
    }

    /// Discards everything buffered, for seeks and stops.
    pub fn clear(&mut self) {
        let n = self.inner.slots();
        if n > 0 {
            self.inner.read_chunk(n).expect("checked availability").commit_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn moves_whole_frames_and_zero_fills_underruns() {
        let (mut w, mut r) = ring(4, 2);
        assert_eq!(w.write(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), 4);
        assert_eq!(w.free_frames(), 0);
        let mut out = [9; 6];
        assert_eq!(r.read(&mut out), 3);
        assert_eq!(out, [1, 2, 3, 4, 5, 6]);
        let mut out = [9; 6];
        assert_eq!(r.read(&mut out), 1);
        assert_eq!(out, [7, 8, 0, 0, 0, 0]);
    }
}
