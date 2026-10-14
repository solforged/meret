//! DSP stages. Each one says whether it changes the samples, which is how the
//! signal path knows whether playback is bit-perfect.

use meret_model::signal;

use crate::Sample;

pub trait Stage: Send {
    /// Processes interleaved samples in place. Runs on the decode thread.
    fn process(&mut self, buf: &mut [Sample], channels: u16);
    fn describe(&self) -> signal::Stage;
}

/// ReplayGain, or any fixed gain. At 0 dB it's a no-op and stays bit-perfect.
pub struct Gain {
    db: f32,
    linear: f32,
}

impl Gain {
    pub fn new(db: f32) -> Self {
        Self { db, linear: 10f32.powf(db / 20.0) }
    }
}

impl Stage for Gain {
    fn process(&mut self, buf: &mut [Sample], _channels: u16) {
        if self.db == 0.0 {
            return;
        }
        // TODO(engine): TPDF dither when reducing to the device's bit depth.
        for s in buf {
            *s = (*s as f32 * self.linear).clamp(i32::MIN as f32, i32::MAX as f32) as i32;
        }
    }

    fn describe(&self) -> signal::Stage {
        signal::Stage {
            name: "ReplayGain".into(),
            detail: format!("{:+.1} dB", self.db),
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
}
