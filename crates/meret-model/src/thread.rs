//! Threads: typed, sourced relations you can follow. See docs/navigation.md.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadKind {
    ComposedBy,
    ArrangedBy,
    LyricsBy,
    SungBy,
    PerformedBy,
    ConductedBy,
    ProducedBy,
    EngineeredBy,
    MemberOf,
    WorkedWith,
    RecordingOf,
    ArrangedAs,
    CoverOf,
    Sampled,
    SameSession,
    Scored,
    Label,
    Cites,
    SoundsLike,
    ListenedAfter,
}

impl ThreadKind {
    /// The phrase drawn on the trail strip between two stars.
    pub fn label(self) -> &'static str {
        match self {
            Self::ComposedBy => "composed by",
            Self::ArrangedBy => "arranged by",
            Self::LyricsBy => "lyrics by",
            Self::SungBy => "sung by",
            Self::PerformedBy => "performed by",
            Self::ConductedBy => "conducted by",
            Self::ProducedBy => "produced by",
            Self::EngineeredBy => "engineered by",
            Self::MemberOf => "member of",
            Self::WorkedWith => "worked with",
            Self::RecordingOf => "recording of",
            Self::ArrangedAs => "arranged as",
            Self::CoverOf => "cover of",
            Self::Sampled => "sampled",
            Self::SameSession => "same session",
            Self::Scored => "scored",
            Self::Label => "label",
            Self::Cites => "cites",
            Self::SoundsLike => "sounds like",
            Self::ListenedAfter => "listened after",
        }
    }

    /// Threads Meret derives itself rather than reads from a catalogue.
    pub fn is_local(self) -> bool {
        matches!(self, Self::SoundsLike | Self::ListenedAfter)
    }
}

/// Who said so. Every claim, credit and thread carries one.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Provenance {
    /// A provider key: "musicbrainz", "vgmdb", "local_audio", "you".
    pub source: String,
    /// The provider's own reference, if any (an MBID, a VGMdb album ID).
    pub external_ref: Option<String>,
    /// Unix milliseconds.
    pub fetched_at: i64,
    /// 0.0 to 1.0. Catalogue facts are near 1; audio similarity is the score.
    pub confidence: f32,
}

impl Provenance {
    pub fn you(now_ms: i64) -> Self {
        Self { source: "you".into(), external_ref: None, fetched_at: now_ms, confidence: 1.0 }
    }

    /// The short code shown on rows: MB, VGMdb, Discogs, audio.
    pub fn short(&self) -> &str {
        match self.source.as_str() {
            "musicbrainz" => "MB",
            "vgmdb" => "VGMdb",
            "discogs" => "Discogs",
            "listenbrainz" => "ListenBrainz",
            "wikipedia" => "Wikipedia",
            "local_audio" => "audio",
            "library" => "your library",
            other => other,
        }
    }
}
