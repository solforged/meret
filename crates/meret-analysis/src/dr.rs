/// Dynamic range by the TT DR meter's method, as the Dynamic Range Database
/// reports it: per channel, split into 3-second blocks, take each block's
/// RMS (scaled by √2) and peak, average the loudest 20% of blocks by RMS,
/// and compare with the second-highest peak. The result is the mean over
/// channels, rounded.
pub fn dynamic_range(samples: &[f32], channels: usize, sample_rate: u32) -> Option<u8> {
    if channels == 0 || samples.len() < channels {
        return None;
    }
    let block = (sample_rate as usize * 3).max(1);
    let frames = samples.len() / channels;
    let mut per_channel = vec![];

    for ch in 0..channels {
        let mut rms = vec![];
        let mut peaks = vec![];
        let mut start = 0;
        while start < frames {
            let end = (start + block).min(frames);
            let (mut sum, mut peak) = (0f64, 0f32);
            for f in start..end {
                let x = samples[f * channels + ch];
                sum += (x as f64) * (x as f64);
                peak = peak.max(x.abs());
            }
            rms.push((2.0 * sum / (end - start) as f64).sqrt());
            peaks.push(peak);
            start = end;
        }
        rms.sort_by(|a, b| b.total_cmp(a));
        peaks.sort_by(|a, b| b.total_cmp(a));
        let top = ((rms.len() as f64 * 0.2).round() as usize).max(1);
        let rms_top = (rms[..top].iter().map(|r| r * r).sum::<f64>() / top as f64).sqrt();
        let peak = *peaks.get(1).unwrap_or(&peaks[0]) as f64;
        if rms_top > 0.0 && peak > 0.0 {
            per_channel.push(20.0 * (peak / rms_top).log10());
        }
    }
    if per_channel.is_empty() {
        return None;
    }
    let dr = per_channel.iter().sum::<f64>() / per_channel.len() as f64;
    Some(dr.round().clamp(0.0, 40.0) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sine(amp: f32, secs: f32) -> Vec<f32> {
        let n = (44_100.0 * secs) as usize;
        (0..n).flat_map(|i| {
            let s = amp * (i as f32 / 44_100.0 * 440.0 * std::f32::consts::TAU).sin();
            [s, s]
        }).collect()
    }

    #[test]
    fn a_steady_sine_has_no_dynamic_range_at_any_level() {
        assert_eq!(dynamic_range(&sine(0.9, 30.0), 2, 44_100), Some(0));
        assert_eq!(dynamic_range(&sine(0.1, 30.0), 2, 44_100), Some(0));
    }

    #[test]
    fn quiet_music_with_loud_moments_scores_higher() {
        // Mostly quiet, with two loud blocks of peaks.
        let mut s = sine(0.05, 30.0);
        for i in [100_000usize, 600_000] {
            s[i] = 0.9;
            s[i + 1] = 0.9;
        }
        assert!(dynamic_range(&s, 2, 44_100).unwrap() >= 20);
    }
}
