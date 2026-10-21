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
    /// Composers, arrangers, performers and the rest, in tag order.
    pub credits: Vec<RoleTag>,
    pub genre: Option<String>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub year: Option<u16>,
    /// The composition this is a recording of, and a movement within it.
    pub work: Option<String>,
    pub movement: Option<String>,
    pub movement_number: Option<u32>,
    /// Who wrote the work when the recording credits someone else, as in an
    /// arrangement of a folk tune: ORIGINAL_COMPOSER in Vorbis comments.
    pub original_composer: Option<String>,
    pub label: Option<String>,
    pub catalog_number: Option<String>,
    pub mb_recording: Option<String>,
    pub mb_release: Option<String>,
    pub mb_release_group: Option<String>,
    pub mb_work: Option<String>,
    /// One per artist, in the artist tag's order.
    pub mb_artists: Vec<String>,
    pub mb_album_artists: Vec<String>,
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

/// One role's tag: every value as written. A performer value may name an
/// instrument in parentheses: "Joji Hirota (shakuhachi)".
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoleTag {
    /// As the store's `credit.role`: composer, lyricist, arranger,
    /// conductor, performer, producer, engineer.
    pub role: &'static str,
    pub values: Vec<String>,
}

/// Tag keys read as credits, and the role each one writes.
const ROLES: [(ItemKey, &str); 8] = [
    (ItemKey::Composer, "composer"),
    (ItemKey::Lyricist, "lyricist"),
    (ItemKey::Arranger, "arranger"),
    (ItemKey::Conductor, "conductor"),
    (ItemKey::Performer, "performer"),
    (ItemKey::Producer, "producer"),
    (ItemKey::Engineer, "engineer"),
    (ItemKey::MixEngineer, "engineer"),
];

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
    let s = |k: ItemKey| tag.get_string(k).map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned);
    let all = |k: ItemKey| tag.get_strings(k).map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned).collect::<Vec<_>>();
    t.title = tag.title().map(|c| c.into_owned());
    t.artist = credit_tags(tag, ItemKey::TrackArtist, ItemKey::TrackArtists, &mut t.artists);
    t.album = tag.album().map(|c| c.into_owned());
    t.genre = tag.genre().map(|c| c.into_owned());
    t.album_artist = credit_tags(tag, ItemKey::AlbumArtist, ItemKey::AlbumArtists, &mut t.album_artists);
    for (key, role) in ROLES {
        let values = all(key);
        if values.is_empty() {
            continue;
        }
        match t.credits.iter_mut().find(|c| c.role == role) {
            Some(credit) => credit.values.extend(values),
            None => t.credits.push(RoleTag { role, values }),
        }
    }
    t.track = tag.track();
    t.disc = tag.disk();
    t.year = tag.date().map(|d| d.year).filter(|&y| y > 0);
    t.work = s(ItemKey::Work);
    t.movement = s(ItemKey::Movement);
    t.movement_number = s(ItemKey::MovementNumber).and_then(|n| n.split('/').next()?.trim().parse().ok());
    t.label = s(ItemKey::Label);
    t.catalog_number = s(ItemKey::CatalogNumber);
    t.mb_recording = s(ItemKey::MusicBrainzRecordingId);
    t.mb_release = s(ItemKey::MusicBrainzReleaseId);
    t.mb_release_group = s(ItemKey::MusicBrainzReleaseGroupId);
    t.mb_work = s(ItemKey::MusicBrainzWorkId);
    t.mb_artists = mbids(all(ItemKey::MusicBrainzArtistId));
    t.mb_album_artists = mbids(all(ItemKey::MusicBrainzReleaseArtistId));
    t.isrc = s(ItemKey::Isrc);
    if matches!(file.file_type(), FileType::Flac | FileType::Vorbis | FileType::Opus | FileType::Speex) {
        t.original_composer = vorbis_comment(path, file.file_type(), "ORIGINAL_COMPOSER");
    }
    Ok(t)
}

/// Several IDs may share one value, split by `/` or `;` as Picard writes them.
fn mbids(values: Vec<String>) -> Vec<String> {
    values.iter().flat_map(|v| v.split(['/', ';'])).map(str::trim).filter(|v| !v.is_empty()).map(str::to_owned).collect()
}

/// A Vorbis comment the generic tag has no key for.
fn vorbis_comment(path: &Path, file_type: FileType, key: &str) -> Option<String> {
    use lofty::config::ParseOptions;
    use lofty::file::AudioFile;
    let mut f = std::fs::File::open(path).ok()?;
    let options = ParseOptions::new().read_properties(false).read_cover_art(false);
    let comments = match file_type {
        FileType::Flac => lofty::flac::FlacFile::read_from(&mut f, options).ok()?.vorbis_comments()?.clone(),
        FileType::Vorbis => lofty::ogg::VorbisFile::read_from(&mut f, options).ok()?.vorbis_comments().clone(),
        FileType::Opus => lofty::ogg::OpusFile::read_from(&mut f, options).ok()?.vorbis_comments().clone(),
        FileType::Speex => lofty::ogg::SpeexFile::read_from(&mut f, options).ok()?.vorbis_comments().clone(),
        _ => return None,
    };
    let values: Vec<&str> = comments.get_all(key).map(str::trim).filter(|v| !v.is_empty()).collect();
    (!values.is_empty()).then(|| values.join("; "))
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
