//! The marks every row carries: availability and identity.
//! Sources and Unmatched stopped being places; these replaced them.

use serde::{Deserialize, Serialize};

/// Streaming service codes shown beside a ringed mark.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Service {
    Spotify,
    Qobuz,
    YouTube,
    Bandcamp,
    Archive,
    Tidal,
}

impl Service {
    pub fn code(self) -> &'static str {
        match self {
            Service::Spotify => "sp",
            Service::Qobuz => "qb",
            Service::YouTube => "yt",
            Service::Bandcamp => "bc",
            Service::Archive => "ia",
            Service::Tidal => "td",
        }
    }
}

/// Filled, half, ringed, dashed.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "service", rename_all = "snake_case")]
pub enum Availability {
    OwnLossless,
    OwnLossy,
    Stream(Service),
    Known,
}

impl Availability {
    /// Lower is better: what plays when several sources exist.
    pub fn rank(self) -> u8 {
        match self {
            Availability::OwnLossless => 0,
            Availability::OwnLossy => 1,
            Availability::Stream(_) => 2,
            Availability::Known => 3,
        }
    }
}

/// How an identity was established, in the order Meret tries them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchMethod {
    /// You said so.
    Manual,
    /// A MusicBrainz ID in the file's tags.
    MbidTag,
    Isrc,
    AcoustId,
    /// Title, artist, length, track count.
    Fuzzy,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Identity {
    Confirmed { method: MatchMethod },
    /// Drawn as `≈`.
    Guessed { method: MatchMethod, confidence: f32 },
    Unknown,
}

impl Identity {
    pub fn is_guess(&self) -> bool {
        !matches!(self, Identity::Confirmed { .. })
    }
}
