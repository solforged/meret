//! Storage.
//!
//! * One writer thread owns the only write connection and batches work into
//!   transactions. Nothing else writes.
//! * A small pool of read connections serves queries.
//! * The hot column store keeps the columns the table sorts, filters and
//!   brushes in memory, so 120 Hz interaction never touches SQLite.
//! * Full-text search finds people, releases and recordings by name.

mod art;
mod columns;
pub mod copies;
pub mod credits;
mod library;
mod migrate;
mod pages;
mod plan;
pub mod search;
mod settings;
mod writer;

use std::path::Path;

use parking_lot::Mutex;
use rusqlite::{Connection, OpenFlags};

pub use art::{Artwork, COVER_SIZES, cover_file};
pub use columns::{ColumnId, Histogram, HotColumns, Row};
pub use library::{LibraryFacts, RecentRelease, ReleaseHead, TrackRow};
pub use pages::{Colleague, PersonPage, PersonRelease, ReleasePage, TrackCredit};
pub use plan::{Plan, format_code, plan};
pub use search::{PersonHit, ReleaseHit};
pub use settings::{LightLevel, Settings};
pub use writer::Writer;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("the writer thread has stopped")]
    WriterGone,
    #[error("a write batch failed to commit: {0}")]
    Commit(String),
}

pub type Result<T> = std::result::Result<T, StoreError>;

pub struct Store {
    pub writer: Writer,
    readers: Mutex<Vec<Connection>>,
    path: std::path::PathBuf,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        let mut conn = Connection::open(path)?;
        configure(&conn)?;
        migrate::run(&mut conn)?;
        let writer = Writer::spawn(conn);
        Ok(Self { writer, readers: Mutex::new(Vec::new()), path: path.to_path_buf() })
    }

    /// Runs `f` on a read connection, opening one if the pool is empty.
    pub fn read<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T> {
        let conn = match self.readers.lock().pop() {
            Some(c) => c,
            None => {
                let c = Connection::open_with_flags(
                    &self.path,
                    OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
                )?;
                configure(&c)?;
                c
            }
        };
        let out = f(&conn);
        self.readers.lock().push(conn);
        Ok(out?)
    }
}

fn configure(conn: &Connection) -> rusqlite::Result<()> {
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "foreign_keys", "ON")?;
    conn.pragma_update(None, "temp_store", "MEMORY")?;
    conn.pragma_update(None, "mmap_size", 1i64 << 30)?;
    // The CLI and the app can share a library; wait out the other's commit.
    conn.busy_timeout(std::time::Duration::from_secs(5))?;
    search::register(conn)
}

/// Takes the next value of the global revision counter. Call inside a write.
pub fn next_rev(tx: &rusqlite::Transaction<'_>) -> rusqlite::Result<i64> {
    tx.query_row("UPDATE rev_counter SET rev = rev + 1 WHERE id = 1 RETURNING rev", [], |r| r.get(0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opens_migrates_and_writes() {
        let dir = std::env::temp_dir().join(format!("meret-store-{}", ulid_like()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();

        let id: i64 = store
            .writer
            .write(|tx| {
                let rev = next_rev(tx)?;
                tx.execute("INSERT INTO agent (kind, name, rev) VALUES (0, 'Yasunori Mitsuda', ?1)", [rev])?;
                Ok(tx.last_insert_rowid())
            })
            .unwrap();

        let name: String =
            store.read(|c| c.query_row("SELECT name FROM agent WHERE id = ?1", [id], |r| r.get(0))).unwrap();
        assert_eq!(name, "Yasunori Mitsuda");
        std::fs::remove_dir_all(dir).ok();
    }

    fn ulid_like() -> u128 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    }
}
