//! Identity: deciding which recording a source is.
//!
//! In order: a MusicBrainz ID in the tags, then ISRC, then an AcoustID
//! fingerprint, then fuzzy metadata. The method and confidence are always
//! kept, and anything below the threshold is shown as `≈` and fixed where
//! you see it.

use meret_model::marks::{Identity, MatchMethod};
use serde::{Deserialize, Serialize};

/// At or above this, a fuzzy or fingerprint match is treated as confirmed.
pub const CONFIRM_AT: f32 = 0.92;

/// What the source says about itself.
#[derive(Clone, Debug, Default)]
pub struct Evidence {
    pub mb_recording: Option<String>,
    pub isrc: Option<String>,
    /// (AcoustID recording MBID, score) from a fingerprint lookup.
    pub acoustid: Option<(String, f32)>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub length_ms: Option<u64>,
}

/// A recording a catalogue offered.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Candidate {
    pub mbid: String,
    pub isrcs: Vec<String>,
    pub title: String,
    pub artist: String,
    pub length_ms: Option<u64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Decision {
    pub mbid: Option<String>,
    pub identity: Identity,
    /// Shown on hover: "MusicBrainz ID in tags", "title 0.97 · artist 1.0 · length ±1 s".
    pub evidence: String,
}

pub fn decide(e: &Evidence, candidates: &[Candidate]) -> Decision {
    if let Some(id) = &e.mb_recording {
        return Decision {
            mbid: Some(id.clone()),
            identity: Identity::Confirmed { method: MatchMethod::MbidTag },
            evidence: "MusicBrainz ID in tags".into(),
        };
    }
    if let Some(isrc) = &e.isrc
        && let Some(c) = candidates.iter().find(|c| c.isrcs.iter().any(|i| i.eq_ignore_ascii_case(isrc)))
    {
        return Decision {
            mbid: Some(c.mbid.clone()),
            identity: Identity::Confirmed { method: MatchMethod::Isrc },
            evidence: format!("ISRC {isrc}"),
        };
    }
    if let Some((mbid, score)) = &e.acoustid {
        return Decision {
            mbid: Some(mbid.clone()),
            identity: judged(MatchMethod::AcoustId, *score),
            evidence: format!("AcoustID {score:.2}"),
        };
    }

    let best = candidates
        .iter()
        .map(|c| (c, fuzzy(e, c)))
        .max_by(|a, b| a.1.0.total_cmp(&b.1.0));
    match best {
        Some((c, (score, why))) if score > 0.5 => {
            Decision { mbid: Some(c.mbid.clone()), identity: judged(MatchMethod::Fuzzy, score), evidence: why }
        }
        _ => Decision { mbid: None, identity: Identity::Unknown, evidence: "no candidate close enough".into() },
    }
}

fn judged(method: MatchMethod, confidence: f32) -> Identity {
    if confidence >= CONFIRM_AT {
        Identity::Confirmed { method }
    } else {
        Identity::Guessed { method, confidence }
    }
}

/// Title and artist similarity, weighed against length.
fn fuzzy(e: &Evidence, c: &Candidate) -> (f32, String) {
    let title = e.title.as_deref().map(|t| similarity(t, &c.title)).unwrap_or(0.0);
    let artist = e.artist.as_deref().map(|a| similarity(a, &c.artist)).unwrap_or(0.5);
    let length = match (e.length_ms, c.length_ms) {
        (Some(a), Some(b)) => {
            let d = a.abs_diff(b) as f32 / 1000.0;
            (1.0 - d / 10.0).clamp(0.0, 1.0)
        }
        _ => 0.5,
    };
    let score = title * 0.5 + artist * 0.3 + length * 0.2;
    (score, format!("title {title:.2} · artist {artist:.2} · length {length:.2}"))
}

/// Token overlap (Dice) on normalised words. Ignores case, punctuation and
/// common filler such as "remastered".
pub fn similarity(a: &str, b: &str) -> f32 {
    let ta = tokens(a);
    let tb = tokens(b);
    if ta.is_empty() || tb.is_empty() {
        return 0.0;
    }
    let shared = ta.iter().filter(|t| tb.contains(t)).count();
    2.0 * shared as f32 / (ta.len() + tb.len()) as f32
}

fn tokens(s: &str) -> Vec<String> {
    const FILLER: &[&str] = &["the", "a", "remastered", "remaster", "version", "feat", "ft"];
    s.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && !FILLER.contains(w) && !w.chars().all(|c| c.is_ascii_digit()))
        .map(str::to_owned)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate() -> Candidate {
        Candidate {
            mbid: "small-two".into(),
            isrcs: vec!["JPDC09800217".into()],
            title: "Small Two of Pieces ~Broken Pieces~".into(),
            artist: "Joanne Hogg".into(),
            length_ms: Some(391_000),
        }
    }

    #[test]
    fn tags_beat_everything() {
        let e = Evidence { mb_recording: Some("x".into()), isrc: Some("JPDC09800217".into()), ..Default::default() };
        assert_eq!(decide(&e, &[candidate()]).identity, Identity::Confirmed { method: MatchMethod::MbidTag });
    }

    #[test]
    fn isrc_confirms() {
        let e = Evidence { isrc: Some("jpdc09800217".into()), ..Default::default() };
        let d = decide(&e, &[candidate()]);
        assert_eq!(d.mbid.as_deref(), Some("small-two"));
        assert_eq!(d.identity, Identity::Confirmed { method: MatchMethod::Isrc });
    }

    #[test]
    fn a_game_rip_with_a_loose_title_is_a_guess() {
        let e = Evidence {
            title: Some("17 - Small Two of Pieces (Remastered)".into()),
            artist: Some("Yasunori Mitsuda".into()),
            length_ms: Some(393_000),
            ..Default::default()
        };
        let d = decide(&e, &[candidate()]);
        assert_eq!(d.mbid.as_deref(), Some("small-two"));
        assert!(d.identity.is_guess(), "{d:?}");
    }
}
