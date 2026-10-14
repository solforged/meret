use serde::{Deserialize, Serialize};

use crate::ids::*;

/// Anything that can be opened as a pane or be the end of a thread.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
pub enum EntityRef {
    Work(WorkId),
    Recording(RecordingId),
    Release(ReleaseId),
    Edition(EditionId),
    Track(TrackId),
    Agent(AgentId),
    Context(ContextId),
    Feed(FeedId),
    Episode(EpisodeId),
    Crate(CrateUid),
    Trail(TrailUid),
    /// The search a trail starts from. Only a root is one; the trail's
    /// `root_query` says what was searched.
    Search,
}

/// The kind alone, for columns and indexes that store `(kind, id)` pairs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum EntityKind {
    Work = 1,
    Recording = 2,
    Release = 3,
    Edition = 4,
    Track = 5,
    Agent = 6,
    Context = 7,
    Feed = 8,
    Episode = 9,
    Crate = 10,
    Trail = 11,
    Search = 12,
}

impl EntityRef {
    pub fn kind(&self) -> EntityKind {
        match self {
            Self::Work(_) => EntityKind::Work,
            Self::Recording(_) => EntityKind::Recording,
            Self::Release(_) => EntityKind::Release,
            Self::Edition(_) => EntityKind::Edition,
            Self::Track(_) => EntityKind::Track,
            Self::Agent(_) => EntityKind::Agent,
            Self::Context(_) => EntityKind::Context,
            Self::Feed(_) => EntityKind::Feed,
            Self::Episode(_) => EntityKind::Episode,
            Self::Crate(_) => EntityKind::Crate,
            Self::Trail(_) => EntityKind::Trail,
            Self::Search => EntityKind::Search,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentKind {
    Person,
    Group,
}
