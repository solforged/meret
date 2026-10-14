//! Decoders. Symphonia covers FLAC, ALAC, WAV, AIFF, MP3, AAC and Vorbis.
//! Planned beside it, each behind a feature: DSD (DSF/DFF), libgme and
//! vgmstream for native game formats with loop points, and FFmpeg as a
//! last resort for WavPack, APE and the rest.

use std::path::Path;

use meret_model::audio::StreamSpec;

use crate::Sample;

#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    #[error("unsupported format: {0}")]
    Unsupported(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("corrupt stream: {0}")]
    Corrupt(String),
}

/// A loop inside a source, in frames. Score sources expose these.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LoopPoints {
    pub start: u64,
    pub end: u64,
}

/// Runs on the decode thread, never in the audio callback, so it may
/// allocate and block on IO.
pub trait Decoder: Send {
    fn spec(&self) -> StreamSpec;

    /// Playable frames, excluding encoder delay and padding, if known.
    fn total_frames(&self) -> Option<u64>;

    fn loop_points(&self) -> Option<LoopPoints> {
        None
    }

    /// Appends the next decoded frames to `out` (interleaved, left-justified
    /// i32). Returns frames appended; 0 means the end.
    fn read(&mut self, out: &mut Vec<Sample>) -> Result<usize, DecodeError>;

    /// Seeks to `frame`; returns the frame actually reached.
    fn seek(&mut self, frame: u64) -> Result<u64, DecodeError>;
}

/// Opens a file with the first decoder that accepts it.
pub fn open(path: &Path) -> Result<Box<dyn Decoder>, DecodeError> {
    #[cfg(feature = "symphonia")]
    {
        return symphonia_impl::SymphoniaDecoder::open(path).map(|d| Box::new(d) as Box<dyn Decoder>);
    }
    #[allow(unreachable_code)]
    Err(DecodeError::Unsupported(path.display().to_string()))
}

/// A sine tone, for tests and for checking an output path without files.
pub struct Tone {
    pub spec: StreamSpec,
    pub frames: u64,
    pub hz: f64,
    pos: u64,
}

impl Tone {
    pub fn new(spec: StreamSpec, seconds: f64, hz: f64) -> Self {
        Self { spec, frames: (seconds * spec.sample_rate as f64) as u64, hz, pos: 0 }
    }
}

impl Decoder for Tone {
    fn spec(&self) -> StreamSpec {
        self.spec
    }

    fn total_frames(&self) -> Option<u64> {
        Some(self.frames)
    }

    fn read(&mut self, out: &mut Vec<Sample>) -> Result<usize, DecodeError> {
        let n = (self.frames - self.pos).min(4096);
        let shift = 32 - self.spec.bits as u32;
        let peak = ((1i64 << (self.spec.bits - 1)) - 1) as f64 * 0.25;
        for i in 0..n {
            let t = (self.pos + i) as f64 / self.spec.sample_rate as f64;
            let s = ((t * self.hz * std::f64::consts::TAU).sin() * peak) as i32;
            for _ in 0..self.spec.channels {
                out.push(s << shift);
            }
        }
        self.pos += n;
        Ok(n as usize)
    }

    fn seek(&mut self, frame: u64) -> Result<u64, DecodeError> {
        self.pos = frame.min(self.frames);
        Ok(self.pos)
    }
}

#[cfg(feature = "symphonia")]
mod symphonia_impl {
    use std::fs::File;
    use std::path::Path;

    use meret_model::audio::{Codec, StreamSpec};
    use symphonia::core::codecs::CodecParameters;
    use symphonia::core::codecs::audio::{AudioDecoder, AudioDecoderOptions, well_known as codecs};
    use symphonia::core::errors::Error as SymError;
    use symphonia::core::formats::probe::Hint;
    use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
    use symphonia::core::io::MediaSourceStream;
    use symphonia::core::meta::MetadataOptions;
    use symphonia::core::units::Timestamp;

    use super::{DecodeError, Decoder};
    use crate::Sample;

    pub struct SymphoniaDecoder {
        format: Box<dyn FormatReader>,
        decoder: Box<dyn AudioDecoder>,
        track_id: u32,
        spec: StreamSpec,
        total: Option<u64>,
        scratch: Vec<Sample>,
    }

    impl SymphoniaDecoder {
        pub fn open(path: &Path) -> Result<Self, DecodeError> {
            let file = File::open(path)?;
            let mss = MediaSourceStream::new(Box::new(file), Default::default());
            let mut hint = Hint::new();
            if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                hint.with_extension(ext);
            }
            let format = symphonia::default::get_probe()
                .probe(&hint, mss, FormatOptions::default(), MetadataOptions::default())
                .map_err(err)?;

            let track = format
                .first_track_known_codec(TrackType::Audio)
                .ok_or_else(|| DecodeError::Unsupported("no audio track".into()))?;
            let Some(CodecParameters::Audio(params)) = &track.codec_params else {
                return Err(DecodeError::Unsupported("no audio codec parameters".into()));
            };
            let track_id = track.id;
            let total = track.num_frames;
            let spec = StreamSpec {
                sample_rate: params.sample_rate.ok_or_else(|| DecodeError::Corrupt("no sample rate".into()))?,
                channels: params.channels.as_ref().map(|c| c.count() as u16).unwrap_or(2),
                bits: params.bits_per_sample.unwrap_or(16) as u8,
                codec: codec_of(params.codec),
            };
            let decoder = symphonia::default::get_codecs()
                .make_audio_decoder(params, &AudioDecoderOptions::default())
                .map_err(err)?;

            Ok(Self { format, decoder, track_id, spec, total, scratch: Vec::new() })
        }
    }

    impl Decoder for SymphoniaDecoder {
        fn spec(&self) -> StreamSpec {
            self.spec
        }

        fn total_frames(&self) -> Option<u64> {
            self.total
        }

        fn read(&mut self, out: &mut Vec<Sample>) -> Result<usize, DecodeError> {
            loop {
                let packet = match self.format.next_packet() {
                    Ok(Some(p)) => p,
                    Ok(None) => return Ok(0),
                    Err(SymError::ResetRequired) => {
                        return Err(DecodeError::Unsupported("stream changed mid-file".into()));
                    }
                    Err(e) => return Err(err(e)),
                };
                if packet.track_id != self.track_id {
                    continue;
                }
                match self.decoder.decode(&packet) {
                    Ok(buf) => {
                        let frames = buf.frames();
                        // Decoders already trim encoder delay and padding.
                        buf.copy_to_vec_interleaved::<i32>(&mut self.scratch);
                        out.extend_from_slice(&self.scratch);
                        if frames > 0 {
                            return Ok(frames);
                        }
                    }
                    // A damaged packet: skip it rather than stop the music.
                    Err(SymError::DecodeError(e)) => tracing::warn!(error = e, "skipped a bad packet"),
                    Err(e) => return Err(err(e)),
                }
            }
        }

        fn seek(&mut self, frame: u64) -> Result<u64, DecodeError> {
            let seeked = self
                .format
                .seek(SeekMode::Accurate, SeekTo::Timestamp { ts: Timestamp::new(frame as i64), track_id: self.track_id })
                .map_err(err)?;
            self.decoder.reset();
            Ok(seeked.actual_ts.get().max(0) as u64)
        }
    }

    fn codec_of(id: symphonia::core::codecs::audio::AudioCodecId) -> Codec {
        match id {
            codecs::CODEC_ID_FLAC => Codec::Flac,
            codecs::CODEC_ID_ALAC => Codec::Alac,
            codecs::CODEC_ID_MP3 => Codec::Mp3,
            codecs::CODEC_ID_AAC => Codec::Aac,
            codecs::CODEC_ID_VORBIS => Codec::Vorbis,
            codecs::CODEC_ID_OPUS => Codec::Opus,
            // Uncompressed PCM sits below the first compressed ID.
            id if id >= codecs::CODEC_ID_PCM_S32LE && id < codecs::CODEC_ID_VORBIS => Codec::Wav,
            _ => Codec::Other,
        }
    }

    fn err(e: SymError) -> DecodeError {
        match e {
            SymError::IoError(e) => DecodeError::Io(e),
            SymError::Unsupported(s) => DecodeError::Unsupported(s.to_string()),
            other => DecodeError::Corrupt(other.to_string()),
        }
    }
}
