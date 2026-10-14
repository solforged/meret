//! MusicBrainz: the spine of the model (works, recordings, releases, credits,
//! relationships). One request a second, with a User-Agent naming a contact.
//! https://musicbrainz.org/doc/MusicBrainz_API

use async_trait::async_trait;
use meret_model::{Provenance, ThreadKind};
use meret_provider::*;
use serde_json::Value;

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
        Capabilities { catalog: true, threads: true, ..Default::default() }
    }
    fn health(&self) -> Health {
        Health::Ok { detail: "open data".into() }
    }
    fn as_catalog(&self) -> Option<&dyn Catalog> {
        Some(self)
    }
    fn as_threads(&self) -> Option<&dyn ThreadSource> {
        Some(self)
    }
}

fn prov(external: &str) -> Provenance {
    Provenance {
        source: "musicbrainz".into(),
        external_ref: Some(external.into()),
        fetched_at: Context::now_ms(),
        confidence: 1.0,
    }
}

#[async_trait]
impl Catalog for MusicBrainz {
    async fn lookup(&self, ctx: &Context, subject: &ExternalRef) -> Result<Vec<Claim>> {
        if subject.namespace != "mbid" || subject.kind != RefKind::Recording {
            // TODO(musicbrainz): releases, release groups, works, artists.
            return Ok(vec![]);
        }
        let url = format!("{BASE}/recording/{}?inc=artist-credits+isrcs+work-rels&fmt=json", subject.value);
        let v = ctx.http.get_json(&url).await?;
        Ok(recording_claims(subject, &v))
    }

    async fn search(&self, _ctx: &Context, _query: &CatalogQuery) -> Result<Vec<CatalogHit>> {
        // TODO(musicbrainz): /ws/2/recording?query=… with Lucene escaping.
        Ok(vec![])
    }
}

#[async_trait]
impl ThreadSource for MusicBrainz {
    async fn threads(&self, ctx: &Context, about: &ExternalRef) -> Result<Vec<ThreadClaim>> {
        if about.kind != RefKind::Agent {
            return Ok(vec![]);
        }
        let url = format!("{BASE}/artist/{}?inc=artist-rels&fmt=json", about.value);
        let v = ctx.http.get_json(&url).await?;
        Ok(artist_threads(about, &v))
    }
}

pub fn recording_claims(subject: &ExternalRef, v: &Value) -> Vec<Claim> {
    let p = prov(&subject.value);
    let mut out = vec![];
    let mut put = |field: Field, value: Value| {
        out.push(Claim { subject: subject.clone(), field, value, provenance: p.clone() });
    };
    if let Some(t) = v["title"].as_str() {
        put(Field::Title, t.into());
    }
    if let Some(l) = v["length"].as_u64() {
        put(Field::LengthMs, l.into());
    }
    if let Some(credits) = v["artist-credit"].as_array() {
        let printed: String = credits
            .iter()
            .map(|c| format!("{}{}", c["name"].as_str().unwrap_or(""), c["joinphrase"].as_str().unwrap_or("")))
            .collect();
        put(Field::ArtistCredit, printed.into());
    }
    for isrc in v["isrcs"].as_array().into_iter().flatten() {
        put(Field::Isrc, isrc.clone());
    }
    out
}

/// Artist relationships become threads: member of, worked with.
pub fn artist_threads(about: &ExternalRef, v: &Value) -> Vec<ThreadClaim> {
    let mut out = vec![];
    for rel in v["relations"].as_array().into_iter().flatten() {
        let kind = match rel["type"].as_str() {
            Some("member of band") => ThreadKind::MemberOf,
            Some("collaboration") | Some("supporting musician") => ThreadKind::WorkedWith,
            _ => continue,
        };
        let Some(id) = rel["artist"]["id"].as_str() else { continue };
        let attrs: Vec<&str> = rel["attributes"].as_array().into_iter().flatten().filter_map(|a| a.as_str()).collect();
        out.push(ThreadClaim {
            from: about.clone(),
            to: ExternalRef::mbid(RefKind::Agent, id),
            to_name: rel["artist"]["name"].as_str().unwrap_or("").into(),
            kind,
            detail: (!attrs.is_empty()).then(|| attrs.join(", ")),
            provenance: prov(&about.value),
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_a_recording() {
        let v: Value = serde_json::from_str(
            r#"{"title":"Small Two of Pieces ~Broken Pieces~","length":391000,
                "artist-credit":[{"name":"Joanne Hogg","joinphrase":""}],"isrcs":["JPDC09800217"]}"#,
        )
        .unwrap();
        let s = ExternalRef::mbid(RefKind::Recording, "x");
        let c = recording_claims(&s, &v);
        assert_eq!(c.len(), 4);
        assert!(c.iter().any(|c| c.field == Field::ArtistCredit && c.value == "Joanne Hogg"));
    }

    #[test]
    fn reads_band_membership_as_a_thread() {
        let v: Value = serde_json::from_str(
            r#"{"relations":[{"type":"member of band","attributes":["lead vocals"],
                "artist":{"id":"iona","name":"Iona"}}]}"#,
        )
        .unwrap();
        let t = artist_threads(&ExternalRef::mbid(RefKind::Agent, "hogg"), &v);
        assert_eq!(t[0].kind, ThreadKind::MemberOf);
        assert_eq!(t[0].to_name, "Iona");
        assert_eq!(t[0].detail.as_deref(), Some("lead vocals"));
    }
}
