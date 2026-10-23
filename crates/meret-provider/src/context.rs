use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use meret_jobs::TokenBucket;
use tokio::sync::Mutex;

use crate::{ProviderError, Result};

/// Everything a provider is allowed to touch.
#[derive(Clone)]
pub struct Context {
    pub http: Http,
    pub kv: Arc<dyn Kv>,
    pub provider: &'static str,
}

impl Context {
    pub fn now_ms() -> i64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
    }
}

/// Cursors and small state, scoped to one provider. Backed by the store's
/// `provider_state` table in the app.
pub trait Kv: Send + Sync {
    fn get(&self, key: &str) -> Option<String>;
    fn set(&self, key: &str, value: &str);
}

#[derive(Default)]
pub struct MemoryKv(std::sync::Mutex<HashMap<String, String>>);

impl Kv for MemoryKv {
    fn get(&self, key: &str) -> Option<String> {
        self.0.lock().ok()?.get(key).cloned()
    }
    fn set(&self, key: &str, value: &str) {
        if let Ok(mut m) = self.0.lock() {
            m.insert(key.into(), value.into());
        }
    }
}

/// Responses kept between runs in the app's cache.db.
pub trait Cache: Send + Sync {
    fn get(&self, url: &str) -> Option<CachedResponse>;
    fn put(&self, url: &str, response: &CachedResponse);
}

#[derive(Clone, Debug, PartialEq)]
pub struct CachedResponse {
    pub status: u16,
    pub body: String,
    pub fetched_at: i64,
}

/// An HTTP client that waits its turn per host.
#[derive(Clone)]
pub struct Http {
    client: reqwest::Client,
    buckets: Arc<Mutex<HashMap<String, TokenBucket>>>,
    limits: Arc<HashMap<&'static str, (u32, i64)>>,
    cache: Option<(Arc<dyn Cache>, i64)>,
}

impl Http {
    /// `user_agent` must identify the app and a contact, as MusicBrainz requires.
    pub fn new(user_agent: &str) -> Self {
        let client = reqwest::Client::builder()
            .user_agent(user_agent)
            .timeout(Duration::from_secs(20))
            .build()
            .expect("http client");
        let limits = HashMap::from([
            ("musicbrainz.org", (1, 1_000)),
            ("query.wikidata.org", (1, 1_000)),
            ("api.acoustid.org", (3, 1_000)),
            ("api.discogs.com", (60, 60_000)),
            ("api.listenbrainz.org", (10, 1_000)),
        ]);
        Self { client, buckets: Arc::default(), limits: Arc::new(limits), cache: None }
    }

    /// Uses fresh cached responses and stores 200s and 404s.
    pub fn with_cache(mut self, cache: Arc<dyn Cache>, ttl_ms: i64) -> Self {
        self.cache = Some((cache, ttl_ms));
        self
    }

    fn cached_response(&self, url: &str, now_ms: i64) -> Option<CachedResponse> {
        let (cache, ttl_ms) = self.cache.as_ref()?;
        let response = cache.get(url)?;
        let age = now_ms.checked_sub(response.fetched_at)?;
        (matches!(response.status, 200 | 404) && age >= 0 && age < *ttl_ms).then_some(response)
    }

    async fn wait_turn(&self, host: &str) {
        let (n, per) = self.limits.get(host).copied().unwrap_or((5, 1_000));
        loop {
            let wait = {
                let mut b = self.buckets.lock().await;
                let now = Context::now_ms();
                let bucket = b.entry(host.to_string()).or_insert_with(|| TokenBucket::new(n, per, now));
                match bucket.take(now) {
                    Ok(()) => return,
                    Err(ms) => ms,
                }
            };
            tokio::time::sleep(Duration::from_millis(wait as u64)).await;
        }
    }

    /// `base` with `params` percent-encoded as its query string.
    pub fn url(base: &str, params: &[(&str, &str)]) -> String {
        reqwest::Url::parse_with_params(base, params).map(String::from).unwrap_or_else(|_| base.to_string())
    }

    pub async fn get_json(&self, url: &str) -> Result<serde_json::Value> {
        if let Some(response) = self.cached_response(url, Context::now_ms()) {
            return match response.status {
                404 => Err(ProviderError::NotFound),
                _ => serde_json::from_str(&response.body).map_err(|e| ProviderError::Parse(e.to_string())),
            };
        }
        let host = reqwest::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_owned)).unwrap_or_default();
        self.wait_turn(&host).await;
        let response = self.client.get(url).send().await.map_err(http_error)?;
        let status = response.status().as_u16();
        match status {
            200..=299 | 404 => {
                let response = CachedResponse {
                    status,
                    body: response.text().await.map_err(http_error)?,
                    fetched_at: Context::now_ms(),
                };
                if matches!(status, 200 | 404)
                    && let Some((cache, _)) = &self.cache
                {
                    cache.put(url, &response);
                }
                if status == 404 {
                    Err(ProviderError::NotFound)
                } else {
                    serde_json::from_str(&response.body).map_err(|e| ProviderError::Parse(e.to_string()))
                }
            }
            429 | 503 => Err(ProviderError::RateLimited(1_000)),
            s => Err(ProviderError::Http(format!("{s} from {host}"))),
        }
    }
}

fn http_error(error: reqwest::Error) -> ProviderError {
    if error.is_connect() || error.is_timeout() {
        ProviderError::Offline(error.to_string())
    } else {
        ProviderError::Http(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct MemoryCache(std::sync::Mutex<HashMap<String, CachedResponse>>);

    impl Cache for MemoryCache {
        fn get(&self, url: &str) -> Option<CachedResponse> {
            self.0.lock().unwrap().get(url).cloned()
        }

        fn put(&self, url: &str, response: &CachedResponse) {
            self.0.lock().unwrap().insert(url.into(), response.clone());
        }
    }

    #[tokio::test]
    async fn cache_hits_do_not_request_or_spend_a_token() {
        let cache = Arc::new(MemoryCache::default());
        let url = "http://never-requested.invalid/item";
        let now = Context::now_ms();
        cache.put(url, &CachedResponse { status: 200, body: r#"{"title":"Cached"}"#.into(), fetched_at: now });
        let http = Http::new("Meret test").with_cache(cache.clone(), 60_000);
        assert_eq!(http.get_json(url).await.unwrap()["title"], "Cached");
        assert!(http.buckets.lock().await.is_empty());

        cache.put(url, &CachedResponse { status: 404, body: "{}".into(), fetched_at: now });
        assert!(matches!(http.get_json(url).await, Err(ProviderError::NotFound)));
        assert!(http.buckets.lock().await.is_empty());
    }

    #[test]
    fn stale_entries_are_not_returned() {
        let cache = Arc::new(MemoryCache::default());
        let url = "http://never-requested.invalid/stale";
        cache.put(url, &CachedResponse { status: 200, body: "{}".into(), fetched_at: 1_000 });
        let http = Http::new("Meret test").with_cache(cache, 500);
        assert!(http.cached_response(url, 1_499).is_some());
        assert!(http.cached_response(url, 1_500).is_none());
        assert!(http.cached_response(url, 999).is_none());
    }
}
