//! Queue gains from measured loudness, limited by the track's true peak.

use meret_model::TrackId;
use meret_store::{Level, Result, Store};

pub(crate) fn queue_gain(store: &Store, track: TrackId, level: Level) -> Result<f64> {
    if level == Level::Off {
        return Ok(0.0);
    }
    let Some(analysis) = store.track_analysis(track)? else { return Ok(0.0) };
    let loudness = match level {
        Level::Off => return Ok(0.0),
        Level::Track => analysis.loudness_lufs,
        Level::Album => store.album_loudness(track)?,
    };
    Ok(gain_db(loudness, analysis.peak_db))
}

fn gain_db(loudness_lufs: Option<f64>, peak_db: Option<f64>) -> f64 {
    let Some(loudness) = loudness_lufs else { return 0.0 };
    let gain = -18.0 - loudness;
    peak_db.map_or(gain, |peak| gain.min(-1.0 - peak))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gain_targets_minus_eighteen_lufs() {
        assert_eq!(gain_db(Some(-14.0), Some(-2.0)), -4.0);
        assert_eq!(gain_db(Some(-23.0), Some(-10.0)), 5.0);
        assert_eq!(gain_db(Some(-18.0), Some(-1.0)), 0.0);
        assert_eq!(gain_db(Some(-18.25), Some(-2.0)), 0.25);
    }

    #[test]
    fn true_peak_caps_boost_and_can_require_attenuation() {
        assert_eq!(gain_db(Some(-23.0), Some(-3.0)), 2.0);
        assert_eq!(gain_db(Some(-23.0), Some(0.5)), -1.5);
        assert_eq!(gain_db(Some(-17.5), Some(0.0)), -1.0);
    }

    #[test]
    fn missing_loudness_leaves_samples_unchanged() {
        assert_eq!(gain_db(None, None), 0.0);
        assert_eq!(gain_db(None, Some(0.0)), 0.0);
        assert_eq!(gain_db(Some(-20.0), None), 2.0);
    }
}
