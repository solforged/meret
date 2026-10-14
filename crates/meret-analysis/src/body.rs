//! The body summary: what the radial drawing on the Now pane is made of.
//!
//! A track is reduced to a few hundred bins of loudness and three bands, plus
//! section marks. It's a few kilobytes, stored with the analysis row, so the
//! UI can draw any track's body instantly without touching audio.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Section {
    pub start_bin: u16,
    /// "A", "B", "verse", "loop".
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BodySummary {
    pub length_ms: u64,
    /// 0–255 per bin, RMS on a dB scale from -60 to 0 dBFS.
    pub loudness: Vec<u8>,
    pub low: Vec<u8>,
    pub mid: Vec<u8>,
    pub high: Vec<u8>,
    pub sections: Vec<Section>,
}

impl BodySummary {
    /// Summarises interleaved samples into `bins` bins.
    pub fn from_samples(samples: &[f32], channels: usize, sample_rate: u32, bins: usize) -> Self {
        let frames = samples.len() / channels.max(1);
        let per_bin = (frames / bins.max(1)).max(1);
        let mono: Vec<f32> =
            (0..frames).map(|f| (0..channels).map(|c| samples[f * channels + c]).sum::<f32>() / channels as f32).collect();

        // Two one-pole filters split the signal into rough bands. Cheap, and
        // enough to draw rings; real features come from the analysis models.
        let a_low = one_pole(250.0, sample_rate);
        let a_high = one_pole(4000.0, sample_rate);
        let (mut lp, mut lp2) = (0f32, 0f32);
        let mut acc = [[0f64; 4]; 1];
        let (mut loud, mut low, mut mid, mut high) = (vec![], vec![], vec![], vec![]);

        for (i, &x) in mono.iter().enumerate() {
            lp += a_low * (x - lp);
            lp2 += a_high * (x - lp2);
            let (l, h) = (lp, x - lp2);
            let m = x - l - h;
            for (j, v) in [x, l, m, h].into_iter().enumerate() {
                acc[0][j] += (v * v) as f64;
            }
            if (i + 1) % per_bin == 0 || i + 1 == mono.len() {
                let n = ((i % per_bin) + 1) as f64;
                let [a, b, c, d] = acc[0].map(|s| db_byte((s / n).sqrt()));
                loud.push(a);
                low.push(b);
                mid.push(c);
                high.push(d);
                acc = [[0f64; 4]; 1];
            }
        }

        Self {
            length_ms: frames as u64 * 1000 / sample_rate.max(1) as u64,
            loudness: loud,
            low,
            mid,
            high,
            sections: vec![],
        }
    }
}

fn one_pole(hz: f32, rate: u32) -> f32 {
    1.0 - (-std::f32::consts::TAU * hz / rate as f32).exp()
}

fn db_byte(rms: f64) -> u8 {
    let db = 20.0 * rms.max(1e-9).log10();
    (((db + 60.0) / 60.0).clamp(0.0, 1.0) * 255.0) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bins_follow_loudness() {
        let rate = 8_000;
        let mut s = vec![0f32; rate as usize * 2];
        for (i, x) in s.iter_mut().enumerate().skip(rate as usize) {
            *x = 0.5 * (i as f32 * 0.3).sin();
        }
        let b = BodySummary::from_samples(&s, 1, rate, 20);
        assert_eq!(b.loudness.len(), 20);
        assert_eq!(b.length_ms, 2000);
        assert!(b.loudness[15] > b.loudness[5] + 100);
    }
}
