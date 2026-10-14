use std::path::Path;

use lofty::file::FileType;
use lofty::prelude::*;

/// What a file says about itself. Matching decides what to believe.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub composer: Option<String>,
    pub genre: Option<String>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub year: Option<u16>,
    pub mb_recording: Option<String>,
    pub mb_release: Option<String>,
    pub isrc: Option<String>,
    pub length_ms: u64,
    pub sample_rate: Option<u32>,
    pub bits: Option<u8>,
    pub channels: Option<u8>,
    pub bitrate_kbps: Option<u32>,
    pub file_type: String,
    /// "FLAC", "ALAC", "AAC", "MP3"…, as the store's `source.codec`.
    pub codec: String,
    pub lossless: bool,
}

#[derive(Debug, thiserror::Error)]
#[error("{path}: {message}")]
pub struct TagError {
    pub path: String,
    pub message: String,
}

pub fn read_tags(path: &Path) -> Result<Tags, TagError> {
    let file = lofty::read_from_path(path).map_err(|e| TagError { path: path.display().to_string(), message: e.to_string() })?;
    let props = file.properties();
    // Lossy codecs have no bit depth; in an MP4 only ALAC and FLAC do.
    // Hybrid WavPack has one either way, so it answers for itself.
    let lossless = match file.file_type() {
        FileType::WavPack => wavpack_lossless(path),
        _ => props.bit_depth().is_some(),
    };
    let codec = match file.file_type() {
        FileType::Flac => "FLAC",
        FileType::Mp4 if lossless => "ALAC",
        FileType::Mp4 | FileType::Aac => "AAC",
        FileType::Mpeg => "MP3",
        FileType::Vorbis => "Vorbis",
        FileType::Opus => "Opus",
        FileType::Wav => "WAV",
        FileType::Aiff => "AIFF",
        FileType::Ape => "APE",
        FileType::WavPack => "WavPack",
        _ => "Other",
    };
    let mut t = Tags {
        length_ms: props.duration().as_millis() as u64,
        sample_rate: props.sample_rate(),
        bits: props.bit_depth(),
        channels: props.channels(),
        bitrate_kbps: props.audio_bitrate(),
        file_type: format!("{:?}", file.file_type()),
        codec: codec.into(),
        lossless,
        ..Default::default()
    };
    let Some(tag) = file.primary_tag().or_else(|| file.first_tag()) else { return Ok(t) };
    let s = |k: ItemKey| tag.get_string(k).map(str::to_owned);
    t.title = tag.title().map(|c| c.into_owned());
    t.artist = tag.artist().map(|c| c.into_owned());
    t.album = tag.album().map(|c| c.into_owned());
    t.genre = tag.genre().map(|c| c.into_owned());
    t.album_artist = s(ItemKey::AlbumArtist);
    t.composer = s(ItemKey::Composer);
    t.track = tag.track();
    t.disc = tag.disk();
    t.year = tag.date().map(|d| d.year).filter(|&y| y > 0);
    t.mb_recording = s(ItemKey::MusicBrainzRecordingId);
    t.mb_release = s(ItemKey::MusicBrainzReleaseId);
    t.isrc = s(ItemKey::Isrc);
    Ok(t)
}

fn wavpack_lossless(path: &Path) -> bool {
    use lofty::config::ParseOptions;
    use lofty::file::AudioFile;
    let Ok(mut f) = std::fs::File::open(path) else { return false };
    lofty::wavpack::WavPackFile::read_from(&mut f, ParseOptions::new()).is_ok_and(|w| w.properties().is_lossless())
}
