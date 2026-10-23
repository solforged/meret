use std::sync::Arc;

use meret_provider::{Cache, CachedResponse, Context, Http, MemoryKv, ProviderError};
use provider_wikidata::{Game, Named, games, games_url, search_games};
use serde_json::{Value, json};

const FIXTURE: &str = include_str!("fixtures/games.json");

fn fixture() -> Value {
    serde_json::from_str(FIXTURE).unwrap()
}

#[test]
fn parses_labels_aliases_dates_and_related_entities() {
    let parsed = games(&fixture());
    assert_eq!(parsed, vec![
        Game {
            qid: "Q2385".into(),
            title: "Harbor Kingdom V".into(),
            aliases: vec!["Aven's Harbor Kingdom V".into(), "HK 5".into(), "HK V".into(), "Harbor Kingdom 5".into()],
            year: Some(2010),
            composers: vec![Named { qid: "Q26844769".into(), name: "Aven Reed".into() }],
            developers: vec!["Paper Harbor".into()],
            platforms: vec!["Window Box".into(), "Pear OS".into(), "Moss OS".into()],
            series: Some(Named { qid: "Q1868663".into(), name: "Harbor Kingdom".into() }),
        },
        Game {
            qid: "Q536851".into(),
            title: "Lantern Vale II".into(),
            aliases: vec!["Lantern | Vale".into(), "Vale\u{1f}II".into()],
            year: Some(1999),
            composers: vec![
                Named { qid: "Q2470862".into(), name: "Mira Quill".into() },
                Named { qid: "Q900000001".into(), name: "Oren Hush".into() },
            ],
            developers: vec!["Glass Orchard".into()],
            platforms: vec!["Game Slab".into()],
            series: Some(Named { qid: "Q2094159".into(), name: "Lantern Vale".into() }),
        },
    ]);

    let mut reversed = fixture();
    reversed["results"]["bindings"].as_array_mut().unwrap().reverse();
    assert_eq!(games(&reversed), parsed, "language precedence and deduplication do not depend on row order");
}

#[test]
fn absent_properties_stay_absent_and_unusable_rows_are_ignored() {
    let title = json!({
        "game": { "type": "uri", "value": "http://www.wikidata.org/entity/Q99" },
        "property": { "type": "literal", "value": "title" },
        "value": { "type": "literal", "xml:lang": "mul", "value": "Bare Island" }
    });
    let mut bad_id = title.clone();
    bad_id["game"]["value"] = json!("http://example.org/entity/Q99");
    let mut other_language = title.clone();
    other_language["game"]["value"] = json!("http://www.wikidata.org/entity/Q100");
    other_language["value"]["xml:lang"] = json!("fr");
    let response = json!({ "results": { "bindings": [null, {}, bad_id, other_language, title] } });
    assert_eq!(games(&response), vec![Game {
        qid: "Q99".into(), title: "Bare Island".into(), aliases: vec![], year: None,
        composers: vec![], developers: vec![], platforms: vec![], series: None,
    }]);
    assert!(games(&json!({})).is_empty());
}

struct Cached {
    url: String,
    status: u16,
}

impl Cache for Cached {
    fn get(&self, url: &str) -> Option<CachedResponse> {
        (url == self.url).then(|| CachedResponse {
            status: self.status,
            body: FIXTURE.into(),
            fetched_at: Context::now_ms(),
        })
    }

    fn put(&self, _: &str, _: &CachedResponse) {
        panic!("a fresh cached search must not make a request");
    }
}

#[tokio::test]
async fn searches_use_the_shared_http_cache_and_propagate_errors() {
    let context = |status| Context {
        http: Http::new("Meret test").with_cache(Arc::new(Cached {
            url: games_url("Lantern Vale"), status,
        }), 60_000),
        kv: Arc::new(MemoryKv::default()),
        provider: "wikidata",
    };
    assert_eq!(search_games(&context(200), "Lantern Vale").await.unwrap(), games(&fixture()));
    assert!(matches!(search_games(&context(404), "Lantern Vale").await, Err(ProviderError::NotFound)));
}
