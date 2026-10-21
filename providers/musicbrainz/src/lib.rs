//! MusicBrainz catalogue facts and relationships.
//! https://musicbrainz.org/doc/MusicBrainz_API

mod parsers;
pub use parsers::{artist, recording, release, work};

use async_trait::async_trait;
use meret_provider::*;

const BASE: &str = "https://musicbrainz.org/ws/2";

pub struct MusicBrainz;

impl Provider for MusicBrainz {
    fn key(&self) -> &'static str {
        "musicbrainz"
    }
    fn name(&self) -> &'static str {
        "MusicBrainz"
    }
    fn capabilities(&self) -> Capabilities {
        Capabilities { catalog: true, ..Default::default() }
    }
    fn health(&self) -> Health {
        Health::Ok { detail: String::new() }
    }
    fn as_catalog(&self) -> Option<&dyn Catalog> {
        Some(self)
    }
}

#[async_trait]
impl Catalog for MusicBrainz {
    async fn lookup(&self, ctx: &Context, subject: &ExternalRef) -> Result<Lookup> {
        if subject.namespace != "mbid" {
            return Ok(Lookup::default());
        }
        let (entity, inc) = match subject.kind {
            RefKind::Release => ("release", "artist-credits+labels+recordings+release-groups"),
            RefKind::Recording => ("recording", "artist-credits+artist-rels+work-rels+isrcs"),
            RefKind::Agent => ("artist", "artist-rels"),
            RefKind::Work => ("work", "artist-rels"),
            _ => return Ok(Lookup::default()),
        };
        let url = format!("{BASE}/{entity}/{}?inc={inc}&fmt=json", subject.value);
        let value = ctx.http.get_json(&url).await?;
        let mut lookup = match subject.kind {
            RefKind::Release => release(subject, &value),
            RefKind::Recording => recording(subject, &value),
            RefKind::Agent => artist(subject, &value),
            RefKind::Work => {
                let url = format!("{BASE}/recording?work={}&inc=artist-credits&limit=100&fmt=json", subject.value);
                let recordings = ctx.http.get_json(&url).await?;
                work(subject, &value, &recordings)
            }
            _ => unreachable!(),
        };
        let now = Context::now_ms();
        for claim in &mut lookup.claims {
            claim.provenance.fetched_at = now;
        }
        for thread in &mut lookup.threads {
            thread.provenance.fetched_at = now;
        }
        Ok(lookup)
    }

    async fn search(&self, _ctx: &Context, _query: &CatalogQuery) -> Result<Vec<CatalogHit>> {
        Ok(vec![])
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;

    use serde_json::json;

    use super::*;

    struct FixtureCache(HashMap<String, CachedResponse>);

    impl Cache for FixtureCache {
        fn get(&self, url: &str) -> Option<CachedResponse> {
            Some(self.0.get(url).expect("unexpected request URL").clone())
        }

        fn put(&self, _url: &str, _response: &CachedResponse) {
            panic!("cached lookups must not request the network");
        }
    }

    #[tokio::test]
    async fn catalog_dispatches_all_kinds_and_joins_the_work_browse() {
        let fixtures = [
            ("release/release?inc=artist-credits+labels+recordings+release-groups&fmt=json", include_str!("../tests/fixtures/release.json").into()),
            ("recording/recording?inc=artist-credits+artist-rels+work-rels+isrcs&fmt=json", include_str!("../tests/fixtures/recording.json").into()),
            ("artist/artist?inc=artist-rels&fmt=json", include_str!("../tests/fixtures/artist.json").into()),
            ("work/work?inc=artist-rels&fmt=json", json!({"title":"Cloud Study"}).to_string()),
            ("recording?work=work&inc=artist-credits&limit=100&fmt=json", json!({"recording-count":150,"recordings":[{"id":"other","title":"Cloud Study live"}]}).to_string()),
        ];
        let now = Context::now_ms();
        let cache = FixtureCache(fixtures.into_iter().map(|(path, body)| {
            (format!("{BASE}/{path}"), CachedResponse { status: 200, body, fetched_at: now })
        }).collect());
        let ctx = Context {
            http: Http::new("Meret test").with_cache(Arc::new(cache), 60_000),
            kv: Arc::new(MemoryKv::default()),
            provider: "musicbrainz",
        };
        for (kind, id) in [(RefKind::Release, "release"), (RefKind::Recording, "recording"), (RefKind::Agent, "artist"), (RefKind::Work, "work")] {
            let lookup = MusicBrainz.lookup(&ctx, &ExternalRef::mbid(kind, id)).await.unwrap();
            assert!(!lookup.claims.is_empty());
            assert!(lookup.claims.iter().all(|c| c.provenance.source == "musicbrainz" && c.provenance.fetched_at >= now));
            if kind == RefKind::Work {
                assert!(lookup.claims.iter().any(|c| c.field == Field::RecordingCount && c.value == 150));
                assert_eq!(lookup.threads.len(), 1);
                assert_eq!(lookup.threads[0].to.value, "work");
                assert_eq!(lookup.threads[0].from.value, "other");
            }
        }
        for subject in [
            ExternalRef::mbid(RefKind::Edition, "unsupported"),
            ExternalRef { namespace: "elsewhere".into(), kind: RefKind::Recording, value: "unsupported".into() },
        ] {
            assert_eq!(MusicBrainz.lookup(&ctx, &subject).await.unwrap(), Lookup::default());
        }
    }
}
