//! Idioms: small bundles of rules that say how a kind of music behaves.
//! See docs/idioms.md. The rules that affect playback live here so the
//! player, the queue and the resume list all agree.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum Idiom {
    /// Rock, pop, metal, indie, hip hop.
    Album = 1,
    /// Country, folk, singer-songwriter.
    Song = 2,
    /// Classical, opera, early music.
    Work = 3,
    /// Jazz, much blues.
    Session = 4,
    /// Game, film, TV, anime.
    Score = 5,
    /// DJ mixes, live sets, long-form ambient, jam bands.
    Set = 6,
    /// Podcasts, audiobooks, lectures.
    Spoken = 7,
}

/// Where playback picks up after a pause, per plate 09.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResumePolicy {
    /// The exact frame: a cue, a set.
    Exact,
    /// A little before where it stopped, so a sentence isn't cut: spoken word.
    Rewind { ms: u32 },
    /// The start of the part that was playing, never mid-movement: works.
    StartOfPart,
    /// The start of the track that was playing: albums, songs, sessions.
    StartOfTrack,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ShufflePolicy {
    /// Tracks may be shuffled freely.
    Tracks,
    /// Shuffle whole releases; keep the order inside each.
    Releases,
    /// Never split: shuffle only whole works or whole sets.
    Never,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GainMode {
    Album,
    Track,
    Off,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum LoopPolicy {
    /// Play straight through; ignore loop points.
    Ignore,
    /// Intro, then the loop `times` times, then fade over `fade_ms`.
    Count { times: u8, fade_ms: u32 },
    /// Loop until told otherwise.
    Forever,
}

impl Idiom {
    pub const ALL: [Idiom; 7] = [
        Idiom::Album,
        Idiom::Song,
        Idiom::Work,
        Idiom::Session,
        Idiom::Score,
        Idiom::Set,
        Idiom::Spoken,
    ];

    pub fn resume(self) -> ResumePolicy {
        match self {
            Idiom::Score | Idiom::Set => ResumePolicy::Exact,
            Idiom::Spoken => ResumePolicy::Rewind { ms: 5_000 },
            Idiom::Work => ResumePolicy::StartOfPart,
            Idiom::Album | Idiom::Song | Idiom::Session => ResumePolicy::StartOfTrack,
        }
    }

    pub fn shuffle(self) -> ShufflePolicy {
        match self {
            Idiom::Song | Idiom::Score => ShufflePolicy::Tracks,
            Idiom::Album | Idiom::Session => ShufflePolicy::Releases,
            Idiom::Work | Idiom::Set | Idiom::Spoken => ShufflePolicy::Never,
        }
    }

    pub fn gain(self) -> GainMode {
        match self {
            Idiom::Album | Idiom::Work | Idiom::Session | Idiom::Set => GainMode::Album,
            Idiom::Song | Idiom::Score => GainMode::Track,
            Idiom::Spoken => GainMode::Off,
        }
    }

    /// Whether adjacent items must join without a gap.
    pub fn strictly_gapless(self) -> bool {
        matches!(self, Idiom::Work | Idiom::Set | Idiom::Album | Idiom::Session)
    }

    pub fn default_loop(self) -> LoopPolicy {
        match self {
            Idiom::Score => LoopPolicy::Count { times: 2, fade_ms: 8_000 },
            _ => LoopPolicy::Ignore,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Idiom::Album => "album",
            Idiom::Song => "song",
            Idiom::Work => "work",
            Idiom::Session => "session",
            Idiom::Score => "score",
            Idiom::Set => "set",
            Idiom::Spoken => "spoken",
        }
    }

    /// What Home, the facets and a door's pane call the idiom.
    pub fn plural(self) -> &'static str {
        match self {
            Idiom::Album => "Albums",
            Idiom::Song => "Songs",
            Idiom::Work => "Works",
            Idiom::Session => "Sessions",
            Idiom::Score => "Scores",
            Idiom::Set => "Sets",
            Idiom::Spoken => "Spoken",
        }
    }

    /// Accepts the singular and the plural the Front uses ("scores", "works").
    pub fn parse(s: &str) -> Option<Idiom> {
        let s = s.to_ascii_lowercase();
        let s = s.strip_suffix('s').unwrap_or(&s);
        Idiom::ALL.into_iter().find(|i| i.as_str() == s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn works_never_shuffle_or_resume_mid_movement() {
        assert_eq!(Idiom::Work.shuffle(), ShufflePolicy::Never);
        assert_eq!(Idiom::Work.resume(), ResumePolicy::StartOfPart);
    }

    #[test]
    fn parses_plurals() {
        assert_eq!(Idiom::parse("Scores"), Some(Idiom::Score));
        assert_eq!(Idiom::parse("sets"), Some(Idiom::Set));
        assert_eq!(Idiom::parse("work"), Some(Idiom::Work));
        assert_eq!(Idiom::parse("polka"), None);
    }
}
