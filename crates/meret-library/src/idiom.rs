//! A first idiom for a release, from what one file says about itself.
//!
//! These are the cheap signals of idioms.md: native chiptune formats and
//! audiobook containers, genre tags, and tracks over 40 minutes. MusicBrainz
//! genres and local audio classification come later and outrank them; your
//! own choice outranks everything.

use std::path::Path;

use meret_model::Idiom;

use crate::tags::Tags;

/// Where a release's idiom came from, as stored in `release.idiom_source`.
pub mod source {
    /// Set by hand. Nothing else overwrites it.
    pub const YOU: &str = "you";
    /// From a genre tag.
    pub const TAGS: &str = "tags";
    /// From the file itself: its format or its length.
    pub const STRUCTURE: &str = "structure";
    /// Nothing said otherwise, so Album. Any signal replaces it.
    pub const DEFAULT: &str = "default";
}

const CHIPTUNE: &[&str] = &[
    "spc", "nsf", "nsfe", "vgm", "vgz", "gbs", "psf", "minipsf", "psf2", "minipsf2", "usf", "miniusf", "gsf",
    "minigsf", "2sf", "mini2sf", "hes", "kss", "ay", "sap",
];

/// Genre words, checked in this order, so "game soundtrack, orchestral"
/// is a Score before it can be a Work.
const GENRES: &[(Idiom, &[&str])] = &[
    (Idiom::Spoken, &["podcast", "audiobook", "audio book", "spoken", "speech", "lecture"]),
    (Idiom::Score, &["soundtrack", "score", "ost", "game", "vgm", "anime", "film", "chiptune"]),
    (Idiom::Set, &["dj mix", "dj-mix", "live set", "continuous mix"]),
    (Idiom::Work, &["classical", "opera", "baroque", "symphony", "concerto", "chamber", "early music", "choral"]),
    (Idiom::Session, &["jazz", "bebop", "bop", "swing", "blues"]),
    (Idiom::Song, &["country", "folk", "singer-songwriter", "singer/songwriter", "americana", "bluegrass"]),
    (Idiom::Album, &["rock", "pop", "metal", "indie", "hip hop", "hip-hop", "rap", "punk", "electronic", "soul", "r&b"]),
];

/// A track longer than this is a set, not an album track.
const SET_TRACK_MS: u64 = 40 * 60 * 1000;

/// The idiom `rel_path` and its tags point at, and which kind of signal
/// said so; `None` when nothing does.
pub fn signal(rel_path: &str, tags: &Tags) -> Option<(Idiom, &'static str)> {
    let ext = Path::new(rel_path).extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase);
    match ext.as_deref() {
        Some(e) if CHIPTUNE.contains(&e) => return Some((Idiom::Score, source::STRUCTURE)),
        Some("m4b") => return Some((Idiom::Spoken, source::STRUCTURE)),
        _ => {}
    }
    if let Some(genre) = tags.genre.as_deref().map(str::to_lowercase) {
        // A word matches the start of a tagged word ("soundtracks"); a phrase
        // ("hip-hop", "dj mix") matches anywhere.
        let words: Vec<&str> = genre.split(|c: char| !c.is_alphanumeric() && c != '&').collect();
        let has = |w: &str| {
            if w.chars().all(|c| c.is_alphanumeric() || c == '&') {
                words.iter().any(|x| x.starts_with(w))
            } else {
                genre.contains(w)
            }
        };
        if let Some((idiom, _)) = GENRES.iter().find(|(_, ws)| ws.iter().any(|w| has(w))) {
            return Some((*idiom, source::TAGS));
        }
    }
    (tags.length_ms >= SET_TRACK_MS).then_some((Idiom::Set, source::STRUCTURE))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tags(genre: Option<&str>, length_ms: u64) -> Tags {
        Tags { genre: genre.map(Into::into), length_ms, ..Default::default() }
    }

    #[test]
    fn genres_formats_and_lengths_each_point_somewhere() {
        let idiom = |path, genre, ms| signal(path, &tags(genre, ms)).map(|s| s.0);
        assert_eq!(idiom("a/01.spc", None, 0), Some(Idiom::Score));
        assert_eq!(idiom("a/book.m4b", Some("Rock"), 0), Some(Idiom::Spoken));
        assert_eq!(idiom("a/01.flac", Some("Video Game Soundtrack; Orchestral"), 0), Some(Idiom::Score));
        assert_eq!(idiom("a/01.flac", Some("Classical"), 0), Some(Idiom::Work));
        assert_eq!(idiom("a/01.flac", Some("Hard Bop"), 0), Some(Idiom::Session));
        assert_eq!(idiom("a/01.flac", Some("Indie Folk"), 0), Some(Idiom::Song));
        assert_eq!(idiom("a/01.flac", Some("Post-Rock"), 0), Some(Idiom::Album));
        assert_eq!(idiom("a/01.flac", Some("Synthpop"), 0), None, "a word must start a tagged word");
        assert_eq!(idiom("a/01.flac", Some("Hostage"), 0), None);
        assert_eq!(idiom("a/mix.flac", None, 75 * 60 * 1000), Some(Idiom::Set));
        assert_eq!(idiom("a/01.flac", None, 4 * 60 * 1000), None);
    }
}
