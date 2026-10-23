//! Two kinds of identity.
//!
//! Library entities (recordings, releases, people) get `i64` row IDs assigned
//! by the hub. Satellites copy them, so they never need to be globally unique.
//!
//! Things a person makes (listens, notes, trails, crates, wants) can be made on
//! any device and merged later, so they get ULIDs.

use serde::{Deserialize, Serialize};

macro_rules! row_id {
    ($($(#[$m:meta])* $name:ident),* $(,)?) => {$(
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub i64);

        impl From<i64> for $name {
            fn from(v: i64) -> Self { Self(v) }
        }
    )*};
}

macro_rules! uid {
    ($($(#[$m:meta])* $name:ident),* $(,)?) => {$(
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub ulid::Ulid);

        impl $name {
            pub fn new() -> Self { Self(ulid::Ulid::generate()) }
        }

        impl Default for $name {
            fn default() -> Self { Self::new() }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { self.0.fmt(f) }
        }
    )*};
}

row_id! {
    /// A composition: a song, a movement, a cue, a standard.
    WorkId,
    /// A video game a score belongs to.
    GameId,
    /// One captured performance of a work.
    RecordingId,
    /// A published set as people name it (MusicBrainz's release group).
    ReleaseId,
    /// One published form of a release: a remaster, a pressing, a hi-res reissue.
    EditionId,
    /// A recording's place on an edition.
    TrackId,
    /// A person or a group.
    AgentId,
    /// Where a recording is heard: a scene, a level, a show, a set.
    ContextId,
    /// Where bytes come from: a file, a stream URI, a zone's browse path.
    SourceId,
    /// A file on a root.
    FileId,
    /// A library root: a folder on a disk, a share on a NAS.
    RootId,
    /// A podcast or other feed.
    FeedId,
    /// One episode of a feed.
    EpisodeId,
}

uid! {
    ListenUid,
    NoteUid,
    TrailUid,
    StopUid,
    CrateUid,
    WantUid,
    /// One installation of Meret. Stamped on everything a device makes.
    DeviceUid,
}
