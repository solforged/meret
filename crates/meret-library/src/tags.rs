use std::path::Path;

use lofty::file::FileType;
use lofty::prelude::*;

/// What a file says about itself. Matching decides what to believe.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Tags {
    pub title: Option<String>,
    pub artist: Option<String>,
    /// Explicit ARTISTS or repeated ARTIST values; empty means use the heuristic.
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub album_artists: Vec<String>,
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
    t.artist = credit_tags(tag, ItemKey::TrackArtist, ItemKey::TrackArtists, &mut t.artists);
    t.album = tag.album().map(|c| c.into_owned());
    t.genre = tag.genre().map(|c| c.into_owned());
    t.album_artist = credit_tags(tag, ItemKey::AlbumArtist, ItemKey::AlbumArtists, &mut t.album_artists);
    t.composer = s(ItemKey::Composer);
    t.track = tag.track();
    t.disc = tag.disk();
    t.year = tag.date().map(|d| d.year).filter(|&y| y > 0);
    t.mb_recording = s(ItemKey::MusicBrainzRecordingId);
    t.mb_release = s(ItemKey::MusicBrainzReleaseId);
    t.isrc = s(ItemKey::Isrc);
    Ok(t)
}

fn credit_tags(tag: &lofty::tag::Tag, single: ItemKey, multiple: ItemKey, people: &mut Vec<String>) -> Option<String> {
    let written: Vec<_> = tag.get_strings(single).filter(|s| !s.trim().is_empty()).collect();
    *people = tag.get_strings(multiple).filter(|s| !s.trim().is_empty()).map(str::to_owned).collect();
    if people.is_empty() && written.len() > 1 {
        *people = written.iter().map(|s| (*s).to_owned()).collect();
    }
    if written.is_empty() {
        (!people.is_empty()).then(|| people.join("; "))
    } else {
        Some(written.join("; "))
    }
}

fn wavpack_lossless(path: &Path) -> bool {
    use lofty::config::ParseOptions;
    use lofty::file::AudioFile;
    let Ok(mut f) = std::fs::File::open(path) else { return false };
    lofty::wavpack::WavPackFile::read_from(&mut f, ParseOptions::new()).is_ok_and(|w| w.properties().is_lossless())
}
#[cfg(test)]
mod tests {
    use super::*;
    use lofty::tag::{ItemValue, Tag, TagItem, TagType};

    #[test]
    fn explicit_artist_lists_and_repeated_frames_have_precedence() {
        let mut tag = Tag::new(TagType::VorbisComments);
        tag.insert_text(ItemKey::TrackArtist, "Roger Briggs & Mark Cromer".into());
        tag.push(TagItem::new(ItemKey::TrackArtists, ItemValue::Text("Roger Briggs".into())));
        tag.push(TagItem::new(ItemKey::TrackArtists, ItemValue::Text("Mark Cromer".into())));
        let mut values = vec![];
        let written = credit_tags(&tag, ItemKey::TrackArtist, ItemKey::TrackArtists, &mut values);
        assert_eq!(written.as_deref(), Some("Roger Briggs & Mark Cromer"));
        assert_eq!(values, ["Roger Briggs", "Mark Cromer"]);
        tag.remove_key(ItemKey::TrackArtists);
        tag.push(TagItem::new(ItemKey::TrackArtist, ItemValue::Text("Simon & Garfunkel".into())));
        let written = credit_tags(&tag, ItemKey::TrackArtist, ItemKey::TrackArtists, &mut values);
        assert_eq!(written.as_deref(), Some("Roger Briggs & Mark Cromer; Simon & Garfunkel"));
        assert_eq!(crate::splitting::people(written.as_deref(), &values), ["Roger Briggs & Mark Cromer", "Simon & Garfunkel"]);
        tag.insert_text(ItemKey::AlbumArtists, "Earth, Wind & Fire".into());
        let album = credit_tags(&tag, ItemKey::AlbumArtist, ItemKey::AlbumArtists, &mut values);
        assert_eq!(album.as_deref(), Some("Earth, Wind & Fire"));
        assert_eq!(values, ["Earth, Wind & Fire"]);
    }
}

