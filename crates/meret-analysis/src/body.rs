//! A compact radial body built from loudness and three rough frequency bands.

use serde::{Deserialize, Serialize};

pub(crate) const BODY_BINS: usize = 240;
const MAX_ENERGY_BINS: usize = BODY_BINS * 16;
const BLOB_HEADER: &[u8; 5] = b"MBDY\x01";
const BLOB_HEADER_LEN: usize = 15;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BodySummary {
    pub length_ms: u64,
    /// 0–255 per bin, RMS on a dB scale from -60 to 0 dBFS.
    pub loudness: Vec<u8>,
    pub low: Vec<u8>,
    pub mid: Vec<u8>,
    pub high: Vec<u8>,
}

impl BodySummary {
    /// Version 1: magic/version, u16 bin count, u64 milliseconds (little
    /// endian), then loudness, low, mid and high bytes without padding.
    ///
    /// Panics if the four bands differ in length or exceed 65535 bins.
    pub fn pack(&self) -> Vec<u8> {
        let bins = u16::try_from(self.loudness.len()).expect("too many body bins");
        let n = usize::from(bins);
        assert!(self.low.len() == n && self.mid.len() == n && self.high.len() == n,
            "body bands must have equal lengths");
        let mut bytes = Vec::with_capacity(BLOB_HEADER_LEN + n * 4);
        bytes.extend_from_slice(BLOB_HEADER);
        bytes.extend_from_slice(&bins.to_le_bytes());
        bytes.extend_from_slice(&self.length_ms.to_le_bytes());
        for band in [&self.loudness, &self.low, &self.mid, &self.high] {
            bytes.extend_from_slice(band);
        }
        bytes
    }

    /// Rejects unknown versions, truncated payloads and trailing bytes.
    pub fn unpack(bytes: &[u8]) -> Option<Self> {
        if bytes.get(..BLOB_HEADER.len())? != BLOB_HEADER {
            return None;
        }
        let n = usize::from(u16::from_le_bytes(bytes.get(5..7)?.try_into().ok()?));
        let length_ms = u64::from_le_bytes(bytes.get(7..15)?.try_into().ok()?);
        if bytes.len() != BLOB_HEADER_LEN + n * 4 {
            return None;
        }
        let band = |i| bytes[BLOB_HEADER_LEN + i * n..BLOB_HEADER_LEN + (i + 1) * n].to_vec();
        Some(Self { length_ms, loudness: band(0), low: band(1), mid: band(2), high: band(3) })
    }

    fn empty(length_ms: u64, bins: usize) -> Self {
        Self {
            length_ms,
            loudness: vec![0; bins],
            low: vec![0; bins],
            mid: vec![0; bins],
            high: vec![0; bins],
        }
    }
}

#[derive(Clone, Copy, Default)]
struct Energy {
    squares: [f64; 4],
    frames: u64,
}

impl Energy {
    fn merge(self, other: Self) -> Self {
        Self {
            squares: std::array::from_fn(|i| self.squares[i] + other.squares[i]),
            frames: self.frames + other.frames,
        }
    }
}

pub(crate) struct BodyAccumulator {
    sample_rate: u32,
    frames: u64,
    bin_frames: u64,
    current: Energy,
    bins: Vec<Energy>,
    filters: Vec<[f64; 2]>,
    alpha: [f64; 2],
}

impl BodyAccumulator {
    pub(crate) fn new(channels: usize, sample_rate: u32) -> Self {
        let one_pole = |hz: f64| 1.0 - (-std::f64::consts::TAU * hz / f64::from(sample_rate.max(1))).exp();
        Self {
            sample_rate,
            frames: 0,
            bin_frames: u64::from((sample_rate / 10).max(1)),
            current: Energy::default(),
            bins: Vec::with_capacity(MAX_ENERGY_BINS),
            filters: vec![[0.0; 2]; channels],
            alpha: [one_pole(250.0), one_pole(4000.0)],
        }
    }

    pub(crate) fn push_frame(&mut self, frame: &[f32]) {
        // Keep channel energies separate so opposite-phase channels do not
        // disappear from the drawing when averaged.
        for (&sample, filter) in frame.iter().zip(&mut self.filters) {
            let x = f64::from(sample);
            filter[0] += self.alpha[0] * (x - filter[0]);
            filter[1] += self.alpha[1] * (x - filter[1]);
            let low = filter[0];
            let high = x - filter[1];
            let mid = x - low - high;
            for (sum, value) in self.current.squares.iter_mut().zip([x, low, mid, high]) {
                *sum += value * value;
            }
        }
        self.frames += 1;
        self.current.frames += 1;
        if self.current.frames == self.bin_frames {
            self.finish_bin();
        }
    }

    fn finish_bin(&mut self) {
        if self.current.frames == 0 {
            return;
        }
        if self.bins.len() == MAX_ENERGY_BINS {
            self.rebin();
            // The current bin still has the old width. Carry it forward
            // until it reaches the new width instead of creating a short bin.
            if self.current.frames < self.bin_frames {
                return;
            }
        }
        self.bins.push(std::mem::take(&mut self.current));
    }

    fn rebin(&mut self) {
        // All completed bins have the same width. Merge adjacent pairs in
        // place before admitting another bin, keeping storage bounded.
        for i in 0..MAX_ENERGY_BINS / 2 {
            self.bins[i] = self.bins[i * 2].merge(self.bins[i * 2 + 1]);
        }
        self.bins.truncate(MAX_ENERGY_BINS / 2);
        self.bin_frames *= 2;
    }

    pub(crate) fn finish(mut self, bins: usize) -> BodySummary {
        // Always admit the final partial bin, even after rebinning.
        if self.current.frames > 0 {
            if self.bins.len() == MAX_ENERGY_BINS {
                self.rebin();
            }
            self.bins.push(self.current);
        }
        let length_ms = (u128::from(self.frames) * 1000 / u128::from(self.sample_rate.max(1)))
            .min(u128::from(u64::MAX)) as u64;
        let mut body = BodySummary::empty(length_ms, bins);
        if self.frames == 0 || bins == 0 {
            return body;
        }

        let (mut source, mut source_start) = (0, 0.0);
        for i in 0..bins {
            let start = self.frames as f64 * i as f64 / bins as f64;
            let end = self.frames as f64 * (i + 1) as f64 / bins as f64;
            let mut squares = [0.0; 4];
            while source < self.bins.len() {
                let energy = &self.bins[source];
                let source_end = source_start + energy.frames as f64;
                let overlap = end.min(source_end) - start.max(source_start);
                if overlap > 0.0 {
                    for (sum, value) in squares.iter_mut().zip(energy.squares) {
                        *sum += value * (overlap / energy.frames as f64);
                    }
                }
                if source_end >= end {
                    break;
                }
                source_start = source_end;
                source += 1;
            }
            let samples = (end - start) * self.filters.len() as f64;
            let [loudness, low, mid, high] = squares.map(|sum| db_byte((sum / samples).sqrt()));
            body.loudness[i] = loudness;
            body.low[i] = low;
            body.mid[i] = mid;
            body.high[i] = high;
        }
        body
    }
}

fn db_byte(rms: f64) -> u8 {
    let db = 20.0 * rms.max(1e-9).log10();
    (((db + 60.0) / 60.0).clamp(0.0, 1.0) * 255.0) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summarise(samples: &[f32], channels: usize, sample_rate: u32, bins: usize) -> BodySummary {
        let mut body = BodyAccumulator::new(channels, sample_rate);
        for frame in samples.chunks_exact(channels) {
            body.push_frame(frame);
        }
        body.finish(bins)
    }

    #[test]
    fn bins_follow_loudness() {
        let rate = 8_000;
        let mut s = vec![0f32; rate as usize * 2];
        for (i, x) in s.iter_mut().enumerate().skip(rate as usize) {
            *x = 0.5 * (i as f32 * 0.3).sin();
        }
        let b = summarise(&s, 1, rate, 20);
        assert_eq!(b.loudness.len(), 20);
        assert_eq!(b.length_ms, 2000);
        assert!(b.loudness[15] > b.loudness[5] + 100);
    }

    #[test]
    fn rebinning_preserves_energy_and_the_final_partial_bin() {
        let mut body = BodyAccumulator::new(1, 100);
        let frames = MAX_ENERGY_BINS * 10 * 3 + 7;
        for frame in 0..frames {
            body.push_frame(&[if frame < frames / 2 { 0.1 } else { 0.5 }]);
        }
        let b = body.finish(BODY_BINS);
        assert_eq!(b.length_ms, frames as u64 * 10);
        assert_eq!(b.loudness.len(), BODY_BINS);
        assert!((i16::from(b.loudness[0]) - i16::from(db_byte(0.1))).abs() <= 1);
        assert!((i16::from(b.loudness[239]) - i16::from(db_byte(0.5))).abs() <= 1);
        assert!(b.loudness[180] > b.loudness[60] + 50);
    }

    #[test]
    fn short_audio_fills_every_bin_without_dropping_the_tail() {
        let b = summarise(&[0.0, 1.0], 1, 100, BODY_BINS);
        assert_eq!(b.length_ms, 20);
        assert_eq!(b.loudness.len(), BODY_BINS);
        assert_eq!(b.loudness[0], b.loudness[239]);
        assert_eq!(b.loudness[239], db_byte(0.5f64.sqrt()));
    }

    #[test]
    fn opposite_phase_channels_keep_their_energy() {
        let mono = vec![0.25; 100];
        let stereo: Vec<_> = mono.iter().flat_map(|&x| [x, -x]).collect();
        let a = summarise(&mono, 1, 100, 20);
        let b = summarise(&stereo, 2, 100, 20);
        assert_eq!(a, b);
    }

    #[test]
    fn a_partial_source_bin_reaches_the_end_of_the_body() {
        let mut samples = vec![0.0; 10];
        samples.push(1.0);
        let body = summarise(&samples, 1, 100, BODY_BINS);
        assert_eq!(body.length_ms, 110);
        assert_eq!(body.loudness[0], 0);
        assert_eq!(body.loudness[239], 255);
    }

    #[test]
    fn body_blob_roundtrips_all_bands_and_u64_duration() {
        let body = BodySummary {
            length_ms: u64::MAX,
            loudness: (0..BODY_BINS).map(|i| i as u8).collect(),
            low: vec![0; BODY_BINS],
            mid: vec![127; BODY_BINS],
            high: vec![255; BODY_BINS],
        };
        let bytes = body.pack();
        assert_eq!(bytes.len(), BLOB_HEADER_LEN + BODY_BINS * 4);
        assert_eq!(BodySummary::unpack(&bytes), Some(body));
        let empty = BodySummary::empty(0, 0);
        assert_eq!(BodySummary::unpack(&empty.pack()), Some(empty));
    }

    #[test]
    fn malformed_body_blobs_are_rejected() {
        let bytes = BodySummary::empty(1000, BODY_BINS).pack();
        for end in 0..bytes.len() {
            assert!(BodySummary::unpack(&bytes[..end]).is_none());
        }
        for index in [0, 4, 5, 6] {
            let mut corrupt = bytes.clone();
            corrupt[index] ^= 0xff;
            assert!(BodySummary::unpack(&corrupt).is_none());
        }
        let mut trailing = bytes;
        trailing.push(0);
        assert!(BodySummary::unpack(&trailing).is_none());
    }

    #[test]
    #[should_panic(expected = "body bands must have equal lengths")]
    fn unequal_body_bands_cannot_be_packed() {
        let mut body = BodySummary::empty(1000, BODY_BINS);
        body.low.pop();
        body.pack();
    }
}
