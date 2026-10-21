use std::path::Path;

use parking_lot::Mutex;
use rusqlite::{Connection, ErrorCode, OptionalExtension};

use crate::Result;

/// Rebuildable provider responses, separate from the library.
pub struct HttpCache {
    conn: Mutex<Connection>,
}

impl HttpCache {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = match open(path) {
            Ok(conn) => conn,
            Err(error) if matches!(error.sqlite_error_code(), Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase)) => {
                for suffix in ["", "-wal", "-shm"] {
                    let mut file = path.as_os_str().to_os_string();
                    file.push(suffix);
                    match std::fs::remove_file(file) {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                        Err(e) => return Err(e.into()),
                    }
                }
                open(path)?
            }
            Err(error) => return Err(error.into()),
        };
        Ok(Self { conn: Mutex::new(conn) })
    }

    pub fn get(&self, url: &str) -> Option<(u16, String, i64)> {
        self.conn.lock().query_row(
            "SELECT status, body, fetched_at FROM http WHERE url = ?1", [url],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        ).optional().ok().flatten()
    }

    pub fn put(&self, url: &str, status: u16, body: &str, fetched_at: i64) {
        if let Err(error) = self.conn.lock().execute(
            "INSERT INTO http (url, status, body, fetched_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(url) DO UPDATE SET status = excluded.status, body = excluded.body, fetched_at = excluded.fetched_at",
            (url, status, body, fetched_at),
        ) {
            tracing::warn!(%error, "could not cache HTTP response");
        }
    }

    pub fn len(&self) -> u64 {
        self.conn.lock().query_row("SELECT COUNT(*) FROM http", [], |r| r.get::<_, i64>(0)).unwrap_or(0) as u64
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

fn open(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS http (
             url TEXT PRIMARY KEY, status INTEGER NOT NULL, body TEXT NOT NULL, fetched_at INTEGER NOT NULL)",
    )?;
    let integrity: String = conn.query_row("PRAGMA quick_check", [], |r| r.get(0))?;
    if integrity != "ok" {
        return Err(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_CORRUPT), Some(integrity),
        ));
    }
    Ok(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn responses_persist_replace_and_recover_from_corruption() {
        let dir = std::env::temp_dir().join(format!("meret-http-{}", ulid::Ulid::generate()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cache.db");
        let cache = HttpCache::open(&path).unwrap();
        assert!(cache.is_empty());
        assert_eq!(cache.get("missing"), None);
        cache.put("recording", 200, "{}", 100);
        cache.put("work", 404, "not found", 101);
        cache.put("recording", 200, "updated", 102);
        assert_eq!(cache.len(), 2);
        drop(cache);
        let cache = HttpCache::open(&path).unwrap();
        assert_eq!(cache.get("recording"), Some((200, "updated".into(), 102)));
        assert_eq!(cache.get("work"), Some((404, "not found".into(), 101)));
        drop(cache);
        std::fs::write(&path, "broken cache").unwrap();
        let cache = HttpCache::open(&path).unwrap();
        assert!(cache.is_empty());
        cache.put("restored", 200, "ok", 103);
        assert_eq!(cache.get("restored"), Some((200, "ok".into(), 103)));
        drop(cache);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
