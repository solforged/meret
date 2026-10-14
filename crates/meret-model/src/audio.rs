use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Codec {
    Flac,
    Alac,
    Wav,
    Aiff,
    WavPack,
    Ape,
    Dsd,
    Mp3,
    Aac,
    Vorbis,
    Opus,
    /// Native game formats played through emulation: SPC, NSF, VGM, PSF, GBS.
    Chiptune,
    Other,
}

impl Codec {
    pub fn is_lossless(self) -> bool {
        matches!(
            self,
            Codec::Flac | Codec::Alac | Codec::Wav | Codec::Aiff | Codec::WavPack | Codec::Ape | Codec::Dsd | Codec::Chiptune
        )
    }
}

/// The shape of a PCM (or DSD) stream as it leaves a decoder.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct StreamSpec {
    pub sample_rate: u32,
    pub channels: u16,
    /// Meaningful bits per sample. 1 for DSD.
    pub bits: u8,
    pub codec: Codec,
}

impl StreamSpec {
    pub fn is_hi_res(&self) -> bool {
        self.bits > 16 || self.sample_rate > 48_000
    }

    /// "FLAC 16/44.1", "DSD64", "MP3".
    pub fn describe(&self) -> String {
        let codec = format!("{:?}", self.codec).to_uppercase();
        match self.codec {
            Codec::Dsd => format!("DSD{}", self.sample_rate / 44_100),
            c if c.is_lossless() => {
                let khz = self.sample_rate as f64 / 1000.0;
                let khz = if khz.fract() == 0.0 { format!("{khz:.0}") } else { format!("{khz:.1}") };
                format!("{codec} {}/{khz}", self.bits)
            }
            _ => codec,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn describes_like_the_plates() {
        let cd = StreamSpec { sample_rate: 44_100, channels: 2, bits: 16, codec: Codec::Flac };
        assert_eq!(cd.describe(), "FLAC 16/44.1");
        let hr = StreamSpec { sample_rate: 96_000, channels: 2, bits: 24, codec: Codec::Flac };
        assert_eq!(hr.describe(), "FLAC 24/96");
        assert!(hr.is_hi_res() && !cd.is_hi_res());
    }
}
