//! Integrations.
//!
//! A provider declares which capabilities it has; the registry asks by
//! capability. Providers emit *claims* (facts with provenance), never rows,
//! so a misbehaving provider can be switched off and its claims dropped
//! without damaging the library.
//!
//! Adding a service is one crate under `providers/` and one line where the
//! registry is built in `meret-core`.

mod claim;
mod context;
mod registry;

use std::sync::Arc;

use async_trait::async_trait;
use meret_player::Zone;
use serde::{Deserialize, Serialize};

pub use claim::*;
pub use context::{Cache, CachedResponse, Context, Http, Kv, MemoryKv};
pub use registry::Registry;

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("not signed in to {0}")]
    NeedsAuth(&'static str),
    #[error("rate limited; retry in {0} ms")]
    RateLimited(i64),
    #[error("not found")]
    NotFound,
    #[error("http: {0}")]
    Http(String),
    /// No connection, DNS, or a timeout.
    #[error("offline: {0}")]
    Offline(String),
    #[error("unexpected response: {0}")]
    Parse(String),
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, ProviderError>;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Capabilities {
    pub catalog: bool,
    pub threads: bool,
    pub library_sync: bool,
    pub stream_source: bool,
    pub zone_host: bool,
    pub listen_history: bool,
    pub shop: bool,
    pub crawler: bool,
}

/// What the status line shows for a provider.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Health {
    Ok { detail: String },
    Degraded { reason: String },
    NeedsAuth,
    Offline { reason: String },
    Disabled,
}

pub trait Provider: Send + Sync {
    /// Stable key used in provenance and settings: "musicbrainz".
    fn key(&self) -> &'static str;
    /// "MusicBrainz".
    fn name(&self) -> &'static str;
    fn capabilities(&self) -> Capabilities;
    fn health(&self) -> Health;

    fn as_catalog(&self) -> Option<&dyn Catalog> {
        None
    }
    fn as_threads(&self) -> Option<&dyn ThreadSource> {
        None
    }
    fn as_library_sync(&self) -> Option<&dyn LibrarySync> {
        None
    }
    fn as_stream_source(&self) -> Option<&dyn StreamSource> {
        None
    }
    fn as_zone_host(&self) -> Option<&dyn ZoneHost> {
        None
    }
    fn as_listen_history(&self) -> Option<&dyn ListenHistory> {
        None
    }
}

/// Facts about entities: titles, credits, editions, external IDs.
#[async_trait]
pub trait Catalog: Send + Sync {
    async fn lookup(&self, ctx: &Context, subject: &ExternalRef) -> Result<Lookup>;
    async fn search(&self, ctx: &Context, query: &CatalogQuery) -> Result<Vec<CatalogHit>>;
}

/// Typed, sourced relations to follow.
#[async_trait]
pub trait ThreadSource: Send + Sync {
    async fn threads(&self, ctx: &Context, about: &ExternalRef) -> Result<Vec<ThreadClaim>>;
}

/// What you own or saved elsewhere. Pages through with an opaque cursor.
#[async_trait]
pub trait LibrarySync: Send + Sync {
    async fn sync(&self, ctx: &Context, cursor: Option<String>) -> Result<SyncPage>;
}

/// Bytes Meret can decode itself (a Bandcamp download, an Archive FLAC).
#[async_trait]
pub trait StreamSource: Send + Sync {
    async fn resolve(&self, ctx: &Context, uri: &str) -> Result<ResolvedStream>;
}

/// Zones Meret can drive (Roon, Music Assistant, Spotify Connect).
pub trait ZoneHost: Send + Sync {
    fn zones(&self) -> Vec<Arc<dyn Zone>>;
}

#[async_trait]
pub trait ListenHistory: Send + Sync {
    async fn import(&self, ctx: &Context, since_ms: i64) -> Result<Vec<ListenClaim>>;
    async fn submit(&self, ctx: &Context, listen: &ListenClaim) -> Result<()>;
}
