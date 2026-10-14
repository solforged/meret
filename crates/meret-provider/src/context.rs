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

/// An HTTP client that waits its turn per host.
#[derive(Clone)]
pub struct Http {
    client: reqwest::Client,
    buckets: Arc<Mutex<HashMap<String, TokenBucket>>>,
    limits: Arc<HashMap<&'static str, (u32, i64)>>,
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
            ("api.acoustid.org", (3, 1_000)),
            ("api.discogs.com", (60, 60_000)),
            ("api.listenbrainz.org", (10, 1_000)),
        ]);
        Self { client, buckets: Arc::default(), limits: Arc::new(limits) }
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

    pub async fn get_json(&self, url: &str) -> Result<serde_json::Value> {
        let host = reqwest::Url::parse(url).ok().and_then(|u| u.host_str().map(str::to_owned)).unwrap_or_default();
        self.wait_turn(&host).await;
        // TODO(provider): consult and fill cache.db before and after the request.
        let resp = self.client.get(url).send().await.map_err(|e| ProviderError::Http(e.to_string()))?;
        match resp.status().as_u16() {
            200..=299 => resp.json().await.map_err(|e| ProviderError::Parse(e.to_string())),
            404 => Err(ProviderError::NotFound),
            429 | 503 => Err(ProviderError::RateLimited(1_000)),
            s => Err(ProviderError::Http(format!("{s} from {host}"))),
        }
    }
}
