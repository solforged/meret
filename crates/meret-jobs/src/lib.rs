//! Long work as jobs: scanning, tags, fingerprints, matching, analysis,
//! embeddings, sky placement, provider fetches, crawls, sync.
//!
//! Jobs live in the store's `job` table, so they survive restarts and the
//! status line can always say what's running. This crate holds the parts
//! that don't need the database: kinds, resource classes, rate limits and the
//! scheduling decision.

pub mod rate;
pub mod schedule;

pub use rate::TokenBucket;
pub use schedule::{Conditions, Resource, Scheduler};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum JobKind {
    Walk { root: i64 },
    ReadTags { file: i64 },
    Fingerprint { source: i64 },
    Match { source: i64 },
    Analyse { recording: i64 },
    Embed { recording: i64 },
    PlaceOnSky { recording: i64 },
    Fetch { provider: String, what: String },
    Crawl { provider: String },
    Sync { peer: String },
}

impl JobKind {
    /// Collapses duplicates in the queue: one analysis per recording.
    pub fn dedupe_key(&self) -> String {
        match self {
            JobKind::Walk { root } => format!("walk:{root}"),
            JobKind::ReadTags { file } => format!("tags:{file}"),
            JobKind::Fingerprint { source } => format!("fp:{source}"),
            JobKind::Match { source } => format!("match:{source}"),
            JobKind::Analyse { recording } => format!("analyse:{recording}"),
            JobKind::Embed { recording } => format!("embed:{recording}"),
            JobKind::PlaceOnSky { recording } => format!("sky:{recording}"),
            JobKind::Fetch { provider, what } => format!("fetch:{provider}:{what}"),
            JobKind::Crawl { provider } => format!("crawl:{provider}"),
            JobKind::Sync { peer } => format!("sync:{peer}"),
        }
    }

    pub fn resource(&self) -> Resource {
        match self {
            JobKind::Walk { .. } | JobKind::ReadTags { .. } => Resource::Io,
            JobKind::Fingerprint { .. } | JobKind::Analyse { .. } | JobKind::Embed { .. } | JobKind::PlaceOnSky { .. } => {
                Resource::Cpu
            }
            JobKind::Match { .. } => Resource::Net("musicbrainz.org".into()),
            JobKind::Fetch { provider, .. } | JobKind::Crawl { provider } => Resource::Net(provider.clone()),
            JobKind::Sync { .. } => Resource::Io,
        }
    }

    /// How the status line names a group of these: "analysing", "YouTube likes".
    pub fn verb(&self) -> &'static str {
        match self {
            JobKind::Walk { .. } => "scanning",
            JobKind::ReadTags { .. } => "reading tags",
            JobKind::Fingerprint { .. } => "fingerprinting",
            JobKind::Match { .. } => "identifying",
            JobKind::Analyse { .. } => "analysing",
            JobKind::Embed { .. } => "listening",
            JobKind::PlaceOnSky { .. } => "placing",
            JobKind::Fetch { .. } => "fetching",
            JobKind::Crawl { .. } => "crawling",
            JobKind::Sync { .. } => "syncing",
        }
    }
}

/// One line of the status line's job list: "↻ analysing 1,204 of 3,880".
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct JobGroupStatus {
    pub verb: String,
    pub done: u64,
    pub total: u64,
    pub paused_because: Option<String>,
}
