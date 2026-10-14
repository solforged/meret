use meret_model::{Provenance, ThreadKind};
use serde::{Deserialize, Serialize};

/// An identifier in someone else's namespace: ("mbid", "…"), ("vgmdb", "…").
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ExternalRef {
    pub namespace: String,
    pub kind: RefKind,
    pub value: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefKind {
    Recording,
    Work,
    Release,
    Edition,
    Agent,
    Label,
}

impl ExternalRef {
    pub fn mbid(kind: RefKind, value: impl Into<String>) -> Self {
        Self { namespace: "mbid".into(), kind, value: value.into() }
    }
}

/// One fact about one subject, from one source.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Claim {
    pub subject: ExternalRef,
    pub field: Field,
    pub value: serde_json::Value,
    pub provenance: Provenance,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "field", rename_all = "snake_case")]
pub enum Field {
    Title,
    LengthMs,
    Year,
    Isrc,
    Genre,
    Label,
    CatalogNumber,
    /// The credited name as printed ("Mitsuda, Uematsu, Matsueda").
    ArtistCredit,
    /// A person in a role; the value is `{ "agent": ExternalRef, "name": "…", "detail": "…" }`.
    Credit { role: String },
    /// Another identifier for the same subject.
    SameAs,
    /// Where a cue plays; Score idiom.
    Context,
}

/// A relation, with enough on the far end to draw it before it's fetched.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ThreadClaim {
    pub from: ExternalRef,
    pub to: ExternalRef,
    pub to_name: String,
    pub kind: ThreadKind,
    /// "lead vocals", "uilleann pipes", "Xenogears, 1998".
    pub detail: Option<String>,
    pub provenance: Provenance,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CatalogQuery {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub release: Option<String>,
    pub length_ms: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CatalogHit {
    pub subject: ExternalRef,
    pub title: String,
    pub artist: String,
    pub length_ms: Option<u64>,
    pub score: f32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SyncPage {
    pub items: Vec<SyncItem>,
    pub next: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SyncItem {
    /// The service's own URI: spotify:album:…, bandcamp item id.
    pub uri: String,
    pub subject: Option<ExternalRef>,
    pub title: String,
    pub artist: String,
    pub saved_at: Option<i64>,
    pub owned: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ResolvedStream {
    pub url: String,
    pub codec: String,
    pub lossless: bool,
    pub headers: Vec<(String, String)>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ListenClaim {
    pub subject: Option<ExternalRef>,
    pub title: String,
    pub artist: String,
    pub started_at: i64,
    pub played_ms: u64,
}
