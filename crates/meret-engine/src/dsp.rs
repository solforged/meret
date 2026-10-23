//! DSP stages. Each one says whether it changes the samples, which is how the
//! signal path knows whether playback is bit-perfect.

use meret_model::signal;

use crate::Sample;

pub trait Stage: Send {
    /// Processes interleaved samples in place. Runs on the decode thread.
    fn process(&mut self, buf: &mut [Sample], channels: u16);
    fn describe(&self) -> signal::Stage;
}

/// Loudness levelling. At 0 dB samples pass through unchanged.
pub struct Gain {
    db: f64,
    linear: f64,
}

impl Gain {
    pub fn new(db: f64) -> Self {
        Self { db, linear: if db == 0.0 { 1.0 } else { 10f64.powf(db / 20.0) } }
    }

    pub(crate) fn is_unity(&self) -> bool {
        self.db == 0.0
    }
}

impl Stage for Gain {
    fn process(&mut self, buf: &mut [Sample], _channels: u16) {
        if self.is_unity() {
            return;
        }
        for s in buf {
            *s = (*s as f64 * self.linear).round() as i32;
        }
    }

    fn describe(&self) -> signal::Stage {
        signal::Stage {
            name: "Level".into(),
            detail: format!("levelled {:+.1} dB", self.db),
            alters: self.db != 0.0,
            lossy: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_gain_is_transparent() {
        let mut g = Gain::new(0.0);
        let mut buf = [1 << 16, -(1 << 16), 12345 << 8];
        let before = buf;
        g.process(&mut buf, 1);
        assert_eq!(buf, before);
        assert!(!g.describe().alters);
        assert!(Gain::new(-3.2).describe().alters);
    }

    #[test]
    fn gain_scales_both_channels_without_losing_i32_precision() {
        let mut g = Gain::new(20.0 * 0.5f64.log10());
        let mut buf = [i32::MAX - 1, i32::MIN, 100, -100, 0];
        g.process(&mut buf, 2);
        assert_eq!(buf, [(i32::MAX - 1) / 2, i32::MIN / 2, 50, -50, 0]);
        assert!(g.describe().alters);
    }

    #[test]
    fn positive_gain_saturates_instead_of_wrapping() {
        let mut g = Gain::new(20.0 * 2.0f64.log10());
        let mut buf = [100, -100, i32::MAX, i32::MIN, 0];
        g.process(&mut buf, 1);
        assert_eq!(buf, [200, -200, i32::MAX, i32::MIN, 0]);
    }
}
