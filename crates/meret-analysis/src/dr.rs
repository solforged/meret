/// Dynamic range by the TT DR meter's method, as the Dynamic Range Database
/// reports it. Uses the same three-second statistics as [`crate::Analyzer`].
pub fn dynamic_range(samples: &[f32], channels: usize, sample_rate: u32) -> Option<u8> {
    if channels == 0 {
        return None;
    }
    let mut dr = DrAccumulator::new(channels, sample_rate);
    for frame in samples.chunks_exact(channels) {
        dr.push_frame(frame);
    }
    dr.finish()
}

pub(crate) struct DrAccumulator {
    block_frames: u64,
    frames: u64,
    channels: Vec<Channel>,
}

#[derive(Default)]
struct Channel {
    sum: f64,
    peak: f32,
    rms: Vec<f64>,
    peaks: Vec<f32>,
}

impl DrAccumulator {
    pub(crate) fn new(channels: usize, sample_rate: u32) -> Self {
        Self {
            block_frames: (u64::from(sample_rate) * 3).max(1),
            frames: 0,
            channels: (0..channels).map(|_| Channel::default()).collect(),
        }
    }

    pub(crate) fn push_frame(&mut self, frame: &[f32]) {
        for (channel, &sample) in self.channels.iter_mut().zip(frame) {
            channel.sum += f64::from(sample) * f64::from(sample);
            channel.peak = channel.peak.max(sample.abs());
        }
        self.frames += 1;
        if self.frames == self.block_frames {
            self.finish_block();
        }
    }

    fn finish_block(&mut self) {
        if self.frames == 0 {
            return;
        }
        for channel in &mut self.channels {
            channel.rms.push((2.0 * channel.sum / self.frames as f64).sqrt());
            channel.peaks.push(channel.peak);
            channel.sum = 0.0;
            channel.peak = 0.0;
        }
        self.frames = 0;
    }

    pub(crate) fn finish(mut self) -> Option<u8> {
        self.finish_block();
        let (mut sum, mut count) = (0.0, 0);
        for channel in &mut self.channels {
            if channel.rms.is_empty() {
                continue;
            }
            channel.rms.sort_by(|a, b| b.total_cmp(a));
            channel.peaks.sort_by(|a, b| b.total_cmp(a));
            let top = ((channel.rms.len() as f64 * 0.2).round() as usize).max(1);
            let rms = (channel.rms[..top].iter().map(|r| r * r).sum::<f64>() / top as f64).sqrt();
            let peak = f64::from(*channel.peaks.get(1).unwrap_or(&channel.peaks[0]));
            if rms > 0.0 && peak > 0.0 {
                sum += 20.0 * (peak / rms).log10();
                count += 1;
            }
        }
        (count > 0).then(|| (sum / f64::from(count)).round().clamp(0.0, 40.0) as u8)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Analyzer;

    fn sine(amp: f32, secs: f32) -> Vec<f32> {
        let n = (44_100.0 * secs) as usize;
        (0..n).flat_map(|i| {
            let s = amp * (i as f32 / 44_100.0 * 440.0 * std::f32::consts::TAU).sin();
            [s, s]
        }).collect()
    }

    fn streaming(samples: &[f32], channels: usize, sample_rate: u32) -> Option<u8> {
        let mut analyzer = Analyzer::new(channels, sample_rate);
        for chunk in samples.chunks(channels * 1003) {
            analyzer.push(chunk);
        }
        analyzer.finish().dr
    }

    #[test]
    fn a_steady_sine_has_no_dynamic_range_at_any_level() {
        for amplitude in [0.9, 0.1] {
            let samples = sine(amplitude, 30.0);
            let dr = dynamic_range(&samples, 2, 44_100);
            assert_eq!(dr, Some(0));
            assert_eq!(streaming(&samples, 2, 44_100), dr);
        }
    }

    #[test]
    fn quiet_music_with_loud_moments_scores_higher() {
        // Mostly quiet, with two loud blocks of peaks.
        let mut s = sine(0.05, 30.0);
        for i in [100_000usize, 600_000] {
            s[i] = 0.9;
            s[i + 1] = 0.9;
        }
        let dr = dynamic_range(&s, 2, 44_100);
        assert_eq!(dr, Some(25));
        assert_eq!(streaming(&s, 2, 44_100), dr);
    }

    #[test]
    fn partial_blocks_second_peak_and_channel_means_match_the_dr_method() {
        let rate = 8_000;
        let block = rate as usize * 3;
        let mut samples = vec![0.0; (block * 3 + block / 2) * 3];
        for (start, peak) in [(0, 1.0), (block, 0.5), (block * 2, 0.25), (block * 3, 0.1)] {
            samples[start * 3] = peak;
            samples[start * 3 + 1] = 0.1;
        }
        // The channels score 34.77 and 37.78 before averaging. The third,
        // silent channel is excluded. A half block uses its actual length.
        let dr = dynamic_range(&samples, 3, rate);
        assert_eq!(dr, Some(36));
        assert_eq!(streaming(&samples, 3, rate), dr);
    }

    #[test]
    fn empty_silent_and_incomplete_input_have_no_dr() {
        assert_eq!(dynamic_range(&[], 2, 44_100), None);
        assert_eq!(dynamic_range(&[0.0; 100], 2, 44_100), None);
        assert_eq!(dynamic_range(&[1.0], 2, 44_100), None);
        assert_eq!(dynamic_range(&[1.0], 0, 44_100), None);
    }
}
