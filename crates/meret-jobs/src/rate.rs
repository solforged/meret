//! Per-host rate limits. MusicBrainz allows one request a second; AcoustID
//! three; Discogs sixty a minute. A provider that ignores this gets blocked,
//! so every request goes through a bucket.

/// A token bucket driven by an explicit clock, so it's testable and works
/// with any runtime.
#[derive(Clone, Debug)]
pub struct TokenBucket {
    capacity: f64,
    per_ms: f64,
    tokens: f64,
    last_ms: i64,
}

impl TokenBucket {
    pub fn new(requests: u32, per_ms: i64, now_ms: i64) -> Self {
        let capacity = requests as f64;
        Self { capacity, per_ms: capacity / per_ms as f64, tokens: capacity, last_ms: now_ms }
    }

    pub fn per_second(n: u32, now_ms: i64) -> Self {
        Self::new(n, 1_000, now_ms)
    }

    fn refill(&mut self, now_ms: i64) {
        let dt = (now_ms - self.last_ms).max(0) as f64;
        self.tokens = (self.tokens + dt * self.per_ms).min(self.capacity);
        self.last_ms = now_ms;
    }

    /// Takes a token, or says how long to wait for one.
    pub fn take(&mut self, now_ms: i64) -> Result<(), i64> {
        self.refill(now_ms);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            Ok(())
        } else {
            Err(((1.0 - self.tokens) / self.per_ms).ceil() as i64)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn musicbrainz_gets_one_a_second() {
        let mut b = TokenBucket::per_second(1, 0);
        assert_eq!(b.take(0), Ok(()));
        assert_eq!(b.take(10), Err(990));
        assert_eq!(b.take(1_000), Ok(()));
    }
}
