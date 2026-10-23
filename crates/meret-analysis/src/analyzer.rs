use ebur128::{EbuR128, Mode};

use crate::body::{BODY_BINS, BodyAccumulator};
use crate::dr::DrAccumulator;
use crate::BodySummary;

/// One complete track's analysis. Silence and ungated short clips have no
/// integrated loudness; silence also has no finite peak or DR.
#[derive(Clone, Debug, PartialEq)]
pub struct Analysis {
    pub loudness_lufs: Option<f64>,
    /// True peak in dBTP, across every channel.
    pub peak_db: Option<f64>,
    pub dr: Option<u8>,
    pub body: BodySummary,
}

/// Incremental analysis without retaining source PCM. R128 uses a bounded
/// histogram; DR retains only three-second RMS/peak statistics, and the body
/// adaptively merges energy bins to keep its storage bounded.
pub struct Analyzer {
    channels: usize,
    r128: EbuR128,
    dr: DrAccumulator,
    body: BodyAccumulator,
}

impl Analyzer {
    /// Creates an analyser for a fixed interleaved PCM format.
    ///
    /// Panics if the format is not supported by `ebur128`.
    pub fn new(channels: usize, sample_rate: u32) -> Self {
        let r128 = EbuR128::new(
            u32::try_from(channels).expect("too many analysis channels"),
            sample_rate,
            Mode::I | Mode::TRUE_PEAK | Mode::HISTOGRAM,
        ).expect("unsupported analysis format");
        Self {
            channels,
            r128,
            dr: DrAccumulator::new(channels, sample_rate),
            body: BodyAccumulator::new(channels, sample_rate),
        }
    }

    /// Adds complete interleaved frames. Calls need not align to any analysis
    /// block boundary. No samples are copied or kept between calls.
    ///
    /// Panics if `samples` ends in an incomplete frame.
    pub fn push(&mut self, samples: &[f32]) {
        assert!(samples.len().is_multiple_of(self.channels), "incomplete analysis frame");
        self.r128.add_frames_f32(samples).expect("configured R128 modes");
        for frame in samples.chunks_exact(self.channels) {
            self.dr.push_frame(frame);
            self.body.push_frame(frame);
        }
    }

    pub fn finish(mut self) -> Analysis {
        let loudness = self.r128.loudness_global().expect("integrated loudness mode");
        let loudness_lufs = loudness.is_finite().then_some(loudness);

        if self.r128.rate() < 192_000 {
            // Drain the true-peak interpolator's FIR history. Measure loudness
            // first so this padding never contributes to R128 or duration.
            let zeros = vec![0.0; self.channels * 24];
            self.r128.add_frames_f32(&zeros).expect("configured R128 modes");
        }
        let peak = (0..self.r128.channels())
            .map(|channel| self.r128.true_peak(channel).expect("true peak mode"))
            .fold(0.0, f64::max);
        let peak_db = (peak > 0.0).then(|| 20.0 * peak.log10()).filter(|db| db.is_finite());
        Analysis { loudness_lufs, peak_db, dr: self.dr.finish(), body: self.body.finish(BODY_BINS) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(channels: usize, sample_rate: u32, seconds: usize, hz: f64, amplitude: f64) -> Vec<f32> {
        (0..sample_rate as usize * seconds).flat_map(|frame| {
            let sample = (amplitude * (std::f64::consts::TAU * hz * frame as f64 / f64::from(sample_rate)).sin()) as f32;
            std::iter::repeat_n(sample, channels)
        }).collect()
    }

    fn analyse(samples: &[f32], channels: usize, sample_rate: u32, chunk_frames: usize) -> Analysis {
        let mut analyzer = Analyzer::new(channels, sample_rate);
        for chunk in samples.chunks(chunk_frames * channels) {
            analyzer.push(chunk);
        }
        analyzer.finish()
    }

    #[test]
    fn a_minus_twenty_dbfs_sine_measures_about_minus_twenty_three_lufs_mono() {
        let samples = sine(1, 48_000, 3, 1000.0, 0.1);
        let analysis = analyse(&samples, 1, 48_000, 997);
        assert!((analysis.loudness_lufs.unwrap() + 23.0).abs() < 0.15);
        assert!((analysis.peak_db.unwrap() + 20.0).abs() < 0.1);
        assert_eq!(analysis.dr, Some(0));
        assert_eq!(analysis.body.length_ms, 3000);
    }

    #[test]
    fn stereo_loudness_sums_channel_energy() {
        let samples = sine(2, 48_000, 3, 1000.0, 0.1);
        let analysis = analyse(&samples, 2, 48_000, 4093);
        assert!((analysis.loudness_lufs.unwrap() + 20.0).abs() < 0.15);
    }

    #[test]
    fn chunk_boundaries_do_not_change_analysis() {
        let samples = sine(2, 44_100, 7, 440.0, 0.3);
        let whole = analyse(&samples, 2, 44_100, samples.len() / 2);
        let streaming = analyse(&samples, 2, 44_100, 137);
        assert_eq!(whole.dr, streaming.dr);
        assert_eq!(whole.body, streaming.body);
        assert!((whole.loudness_lufs.unwrap() - streaming.loudness_lufs.unwrap()).abs() < 1e-9);
        assert!((whole.peak_db.unwrap() - streaming.peak_db.unwrap()).abs() < 1e-6);
    }

    #[test]
    fn true_peak_includes_intersample_peaks_and_the_tail() {
        let rate = 48_000;
        let samples: Vec<_> = (0..rate).map(|frame| {
            (0.8 * (std::f64::consts::FRAC_PI_2 * f64::from(frame) + std::f64::consts::FRAC_PI_4).sin()) as f32
        }).collect();
        let sample_peak = samples.iter().map(|x| x.abs()).fold(0.0, f32::max);
        let peak = analyse(&samples, 1, rate, 127).peak_db.unwrap();
        assert!(peak > 20.0 * f64::from(sample_peak).log10() + 2.0);
        assert!((-3.0..-1.0).contains(&peak));

        // Only the last four source frames contain energy. Their intersample
        // peak emerges after the final push, when the FIR history is drained.
        let mut tail = vec![0.0; 100];
        tail.extend_from_slice(&[0.7, 0.7, -0.7, -0.7]);
        let tail_analysis = analyse(&tail, 1, rate, 13);
        assert!(tail_analysis.peak_db.unwrap() > 20.0 * 0.7f64.log10() + 0.5);
        assert_eq!(tail_analysis.body.length_ms, 104 * 1000 / u64::from(rate));
    }

    #[test]
    fn body_has_240_bins_with_loudness_and_frequency_structure() {
        let rate = 16_000;
        let mut samples = sine(1, rate, 2, 50.0, 0.1);
        samples.extend(sine(1, rate, 2, 6000.0, 0.5));
        let body = analyse(&samples, 1, rate, 419).body;
        for band in [&body.loudness, &body.low, &body.mid, &body.high] {
            assert_eq!(band.len(), BODY_BINS);
        }
        assert_eq!(body.length_ms, 4000);
        assert!(body.loudness[180] > body.loudness[60] + 50);
        assert!(body.low[60] > body.high[60] + 50);
        assert!(body.high[180] > body.low[180] + 50);
    }

    #[test]
    fn silence_and_empty_input_have_no_finite_metrics() {
        for samples in [vec![], vec![0.0; 48_000]] {
            let analysis = analyse(&samples, 1, 48_000, 1024);
            assert_eq!(analysis.loudness_lufs, None);
            assert_eq!(analysis.peak_db, None);
            assert_eq!(analysis.dr, None);
            assert_eq!(analysis.body.loudness, vec![0; BODY_BINS]);
        }
    }

    #[test]
    #[should_panic(expected = "incomplete analysis frame")]
    fn incomplete_frames_are_rejected_without_retaining_pcm() {
        Analyzer::new(2, 48_000).push(&[0.0]);
    }
}
