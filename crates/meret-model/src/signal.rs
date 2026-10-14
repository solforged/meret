//! The signal path: source → decode → DSP → output, with what each step does.
//! `● Bit-perfect` is computed from this, never asserted.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Stage {
    /// "File", "Decode", "ReplayGain", "Out".
    pub name: String,
    /// "FLAC 16/44.1", "no DSP", "RME ADI-2 · 44.1".
    pub detail: String,
    /// Whether this stage changes the samples.
    pub alters: bool,
    /// Whether the source itself is lossy (only meaningful on the first stage).
    pub lossy: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SignalPath {
    pub stages: Vec<Stage>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Fidelity {
    /// ● The samples reach the device unchanged.
    BitPerfect,
    /// ◐ Something changes the samples: resampling, gain, EQ.
    Altered,
    /// ○ The source is lossy, so there's nothing to be perfect to.
    Lossy,
}

impl SignalPath {
    pub fn fidelity(&self) -> Fidelity {
        if self.stages.iter().any(|s| s.lossy) {
            Fidelity::Lossy
        } else if self.stages.iter().any(|s| s.alters) {
            Fidelity::Altered
        } else {
            Fidelity::BitPerfect
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stage(name: &str, alters: bool, lossy: bool) -> Stage {
        Stage { name: name.into(), detail: String::new(), alters, lossy }
    }

    #[test]
    fn any_altering_stage_breaks_bit_perfect() {
        let mut p = SignalPath { stages: vec![stage("File", false, false), stage("Out", false, false)] };
        assert_eq!(p.fidelity(), Fidelity::BitPerfect);
        p.stages.insert(1, stage("ReplayGain", true, false));
        assert_eq!(p.fidelity(), Fidelity::Altered);
        p.stages[0].lossy = true;
        assert_eq!(p.fidelity(), Fidelity::Lossy);
    }
}
