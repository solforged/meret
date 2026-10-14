//! Scanning a root into the store.
//!
//! The walk and the diff decide what to read; tags are read in parallel in
//! chunks, and each chunk becomes one write through the store's single
//! writer. Removed files are marked missing and an unmounted root is marked
//! offline: nothing a person made can hang off a row that vanished.
//!
//! The rows written are the minimum the table and the queue need: a file, a
//! source, a recording, a track on a medium of a release's default edition,
//! and the artist and album artist as agents. Matching refines them later.

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use meret_model::{EntityKind, RootId};
use meret_store::{Store, StoreError, next_rev};
use rayon::prelude::*;
use rusqlite::{OptionalExtension, Transaction, params};

use crate::diff::diff;
use crate::tags::{Tags, read_tags};
use crate::walk::{FileStat, walk};

/// Files read and written per batch. Small enough for steady progress,
/// large enough that commits don't dominate.
const CHUNK: usize = 256;

/// The first bytes of a file, hashed to confirm a move.
const HEAD: usize = 64 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum ScanError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("no root with id {0}")]
    NoRoot(i64),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Walking,
    Reading,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScanProgress {
    pub phase: Phase,
    pub done: u64,
    pub total: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScanReport {
    pub found: usize,
    pub added: usize,
    pub changed: usize,
    pub moved: usize,
    pub removed: usize,
    /// Files whose tags couldn't be read. They're kept, without a track.
    pub unreadable: usize,
    /// The root wasn't there; it was marked offline and nothing changed.
    pub offline: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Root {
    pub id: RootId,
    pub path: PathBuf,
    pub online: bool,
}

/// Adds a folder as a root, or returns the existing root for it.
pub fn add_root(store: &Store, path: &Path) -> Result<RootId, ScanError> {
    let path = path.canonicalize()?;
    let label = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "/".into());
    let text = path.to_string_lossy().into_owned();
    let id = store.writer.write(move |tx| {
        tx.execute(
            "INSERT INTO root (label, path, kind) VALUES (?1, ?2, 'local') ON CONFLICT(path) DO NOTHING",
            params![label, text],
        )?;
        tx.query_row("SELECT id FROM root WHERE path = ?1", [&text], |r| r.get(0))
    })?;
    Ok(RootId(id))
}

pub fn roots(store: &Store) -> Result<Vec<Root>, ScanError> {
    Ok(store.read(|c| {
        let mut stmt = c.prepare("SELECT id, path, state FROM root ORDER BY id")?;
        let rows = stmt.query_map([], |r| {
            Ok(Root {
                id: RootId(r.get(0)?),
                path: PathBuf::from(r.get::<_, String>(1)?),
                online: r.get::<_, String>(2)? == "online",
            })
        })?;
        rows.collect()
    })?)
}

/// Walks `root`, diffs it against the store, and writes what changed.
/// Blocks; call it from a background thread, never an engine thread.
pub fn scan(store: &Store, root: RootId, progress: &(dyn Fn(ScanProgress) + Sync)) -> Result<ScanReport, ScanError> {
    let dir: Option<String> =
        store.read(|c| c.query_row("SELECT path FROM root WHERE id = ?1", [root.0], |r| r.get(0)).optional())?;
    let dir = PathBuf::from(dir.ok_or(ScanError::NoRoot(root.0))?);
    let mut report = ScanReport::default();

    if !dir.is_dir() {
        store.writer.write(move |tx| tx.execute("UPDATE root SET state = 'offline' WHERE id = ?1", [root.0]))?;
        report.offline = true;
        return Ok(report);
    }

    progress(ScanProgress { phase: Phase::Walking, done: 0, total: 0 });
    let found = walk(&dir);
    report.found = found.len();
    let known = store.read(|c| {
        let mut stmt =
            c.prepare("SELECT rel_path, size, mtime_ns, inode FROM file WHERE root_id = ?1 AND state = 'present'")?;
        let rows = stmt.query_map([root.0], |r| {
            Ok(FileStat {
                rel_path: r.get(0)?,
                size: r.get::<_, i64>(1)? as u64,
                mtime_ns: r.get::<_, i64>(2)? as i128,
                inode: r.get::<_, Option<i64>>(3)?.map(|i| i as u64),
            })
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()
    })?;
    let d = diff(&known, &found);

    // A move is only trusted when the new file starts with the same bytes.
    let mut to_read = d.added;
    let mut removed = d.removed;
    let mut moves = vec![];
    if !d.moved.is_empty() {
        let old_hashes: HashMap<String, Option<Vec<u8>>> = store.read(|c| {
            let mut stmt = c.prepare("SELECT head_hash FROM file WHERE root_id = ?1 AND rel_path = ?2")?;
            d.moved
                .iter()
                .map(|(old, _)| Ok((old.rel_path.clone(), stmt.query_row(params![root.0, old.rel_path], |r| r.get(0))?)))
                .collect()
        })?;
        let checked: Vec<_> = d
            .moved
            .into_par_iter()
            .map(|(old, new)| {
                let same = head_hash(&dir.join(&new.rel_path)).is_some_and(|h| old_hashes[&old.rel_path].as_deref() == Some(&h[..]));
                (old, new, same)
            })
            .collect();
        for (old, new, same) in checked {
            if same {
                moves.push((old, new));
            } else {
                removed.push(old);
                to_read.push(new);
            }
        }
    }

    let outcome = store.writer.write(move |tx| {
        let rev = next_rev(tx)?;
        for f in &removed {
            tx.execute(
                "UPDATE file SET state = 'missing', rev = ?3 WHERE root_id = ?1 AND rel_path = ?2",
                params![root.0, f.rel_path, rev],
            )?;
        }
        // The new path can be taken by a file that went missing earlier; then
        // the move is read as a removal and an addition instead.
        let mut unmovable = vec![];
        let mut moved = 0;
        for (old, new) in moves {
            let n = tx.execute(
                "UPDATE OR IGNORE file SET rel_path = ?3, mtime_ns = ?4, inode = ?5, rev = ?6
                 WHERE root_id = ?1 AND rel_path = ?2",
                params![root.0, old.rel_path, new.rel_path, new.mtime_ns as i64, new.inode.map(|i| i as i64), rev],
            )?;
            if n == 0 {
                tx.execute(
                    "UPDATE file SET state = 'missing', rev = ?3 WHERE root_id = ?1 AND rel_path = ?2",
                    params![root.0, old.rel_path, rev],
                )?;
                unmovable.push(new);
            } else {
                moved += 1;
            }
        }
        Ok((removed.len(), moved, unmovable))
    })?;
    report.removed = outcome.0;
    report.moved = outcome.1;
    to_read.extend(outcome.2);
    report.added = to_read.len();
    report.changed = d.changed.len();
    to_read.extend(d.changed);

    let provenance = store.writer.write(local_tags_provenance)?;
    let root_label = dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let total = to_read.len() as u64;
    let mut done = 0u64;
    progress(ScanProgress { phase: Phase::Reading, done, total });
    for chunk in to_read.chunks(CHUNK) {
        let read: Vec<(FileStat, Option<Vec<u8>>, Option<Tags>)> = chunk
            .par_iter()
            .map(|f| {
                let path = dir.join(&f.rel_path);
                (f.clone(), head_hash(&path), read_tags(&path).ok())
            })
            .collect();
        report.unreadable += read.iter().filter(|r| r.2.is_none()).count();
        let root_label = root_label.clone();
        store.writer.write(move |tx| {
            let rev = next_rev(tx)?;
            let now = now_ms();
            for (stat, hash, tags) in read {
                ingest(tx, root, &root_label, &stat, hash, tags, rev, now, provenance)?;
            }
            Ok(())
        })?;
        done += chunk.len() as u64;
        progress(ScanProgress { phase: Phase::Reading, done, total });
    }

    store.writer.write(move |tx| {
        tx.execute("UPDATE root SET state = 'online', last_walk_at = ?2 WHERE id = ?1", params![root.0, now_ms()])
    })?;
    Ok(report)
}

/// Writes one file and, if its tags could be read, what it holds. A file
/// already known keeps its recording and track, so plays and notes stay.
/// A file whose tags can't be read is marked unreadable, which keeps it out
/// of the diff's known files, so the next scan tries it again.
#[allow(clippy::too_many_arguments)]
fn ingest(
    tx: &Transaction<'_>,
    root: RootId,
    root_label: &str,
    stat: &FileStat,
    hash: Option<Vec<u8>>,
    tags: Option<Tags>,
    rev: i64,
    now: i64,
    provenance: i64,
) -> rusqlite::Result<()> {
    let state = if tags.is_some() { "present" } else { "unreadable" };
    let file: i64 = tx.query_row(
        "INSERT INTO file (root_id, rel_path, size, mtime_ns, inode, head_hash, state, rev, added_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?9, ?7, ?8)
         ON CONFLICT(root_id, rel_path) DO UPDATE SET size = excluded.size, mtime_ns = excluded.mtime_ns,
             inode = excluded.inode, head_hash = excluded.head_hash, state = excluded.state, rev = excluded.rev
         RETURNING id",
        params![root.0, stat.rel_path, stat.size as i64, stat.mtime_ns as i64, stat.inode.map(|i| i as i64), hash, rev, now, state],
        |r| r.get(0),
    )?;
    let Some(t) = tags else { return Ok(()) };

    let rel = Path::new(&stat.rel_path);
    let title = t.title.clone().unwrap_or_else(|| rel.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());
    let album = t.album.clone().unwrap_or_else(|| {
        rel.parent()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| root_label.to_owned())
    });
    let artist = t.artist.as_deref().map(|n| agent(tx, n, rev)).transpose()?;
    let album_artist = match t.album_artist.as_deref() {
        Some(n) => Some(agent(tx, n, rev)?),
        None => artist,
    };
    let release = release(tx, &album, album_artist, t.year, rev, provenance)?;
    let medium = medium(tx, release, t.disc.unwrap_or(1), rev)?;
    let length = t.length_ms as i64;

    let existing: Option<(i64, i64, i64)> = tx
        .query_row(
            "SELECT id, recording_id, track_id FROM source WHERE file_id = ?1 AND kind = 'file'",
            [file],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()?;
    let (source, recording) = match existing {
        Some((source, recording, track)) => {
            tx.execute("UPDATE recording SET title = ?2, length_ms = ?3, rev = ?4 WHERE id = ?1", params![recording, title, length, rev])?;
            tx.execute(
                "UPDATE track SET medium_id = ?2, position = ?3, title = ?4, length_ms = ?5, rev = ?6 WHERE id = ?1",
                params![track, medium, t.track.unwrap_or(0), title, length, rev],
            )?;
            tx.execute(
                "DELETE FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND provenance_id = ?3",
                params![EntityKind::Recording as i64, recording, provenance],
            )?;
            (source, recording)
        }
        None => {
            let recording: i64 = tx.query_row(
                "INSERT INTO recording (title, length_ms, rev) VALUES (?1, ?2, ?3) RETURNING id",
                params![title, length, rev],
                |r| r.get(0),
            )?;
            let track: i64 = tx.query_row(
                "INSERT INTO track (medium_id, position, recording_id, title, length_ms, rev)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6) RETURNING id",
                params![medium, t.track.unwrap_or(0), recording, title, length, rev],
                |r| r.get(0),
            )?;
            let source: i64 = tx.query_row(
                "INSERT INTO source (recording_id, track_id, kind, file_id, rev) VALUES (?1, ?2, 'file', ?3, ?4) RETURNING id",
                params![recording, track, file, rev],
                |r| r.get(0),
            )?;
            (source, recording)
        }
    };
    tx.execute(
        "UPDATE source SET codec = ?2, sample_rate = ?3, bits = ?4, channels = ?5, lossless = ?6, length_ms = ?7, rev = ?8
         WHERE id = ?1",
        params![source, t.codec, t.sample_rate, t.bits, t.channels, t.lossless, length, rev],
    )?;
    if let Some(a) = artist {
        credit(tx, EntityKind::Recording, recording, a, "artist", rev, provenance)?;
    }
    Ok(())
}

fn agent(tx: &Transaction<'_>, name: &str, rev: i64) -> rusqlite::Result<i64> {
    if let Some(id) = tx.query_row("SELECT id FROM agent WHERE name = ?1 LIMIT 1", [name], |r| r.get(0)).optional()? {
        return Ok(id);
    }
    tx.query_row("INSERT INTO agent (kind, name, rev) VALUES (0, ?1, ?2) RETURNING id", params![name, rev], |r| r.get(0))
}

/// A release is its title and album artist, as tagged.
fn release(
    tx: &Transaction<'_>,
    title: &str,
    album_artist: Option<i64>,
    year: Option<u16>,
    rev: i64,
    provenance: i64,
) -> rusqlite::Result<i64> {
    let found: Option<i64> = tx
        .query_row(
            "SELECT rl.id FROM release rl
             LEFT JOIN credit c ON c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist'
             WHERE rl.title = ?1 AND c.agent_id IS ?2
             LIMIT 1",
            params![title, album_artist],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = found {
        if year.is_some() {
            tx.execute("UPDATE release SET year = ?2 WHERE id = ?1 AND year IS NULL", params![id, year])?;
        }
        return Ok(id);
    }
    let id: i64 = tx.query_row(
        "INSERT INTO release (title, year, rev) VALUES (?1, ?2, ?3) RETURNING id",
        params![title, year, rev],
        |r| r.get(0),
    )?;
    tx.execute("INSERT INTO edition (release_id, is_default, rev) VALUES (?1, 1, ?2)", params![id, rev])?;
    if let Some(a) = album_artist {
        credit(tx, EntityKind::Release, id, a, "album_artist", rev, provenance)?;
    }
    Ok(id)
}

fn medium(tx: &Transaction<'_>, release: i64, disc: u32, rev: i64) -> rusqlite::Result<i64> {
    let edition: i64 =
        tx.query_row("SELECT id FROM edition WHERE release_id = ?1 AND is_default = 1", [release], |r| r.get(0))?;
    if let Some(id) = tx
        .query_row("SELECT id FROM medium WHERE edition_id = ?1 AND position = ?2", params![edition, disc], |r| r.get(0))
        .optional()?
    {
        return Ok(id);
    }
    tx.execute("UPDATE edition SET rev = ?2 WHERE id = ?1", params![edition, rev])?;
    tx.query_row(
        "INSERT INTO medium (edition_id, position) VALUES (?1, ?2) RETURNING id",
        params![edition, disc],
        |r| r.get(0),
    )
}

fn credit(
    tx: &Transaction<'_>,
    kind: EntityKind,
    subject: i64,
    agent: i64,
    role: &str,
    rev: i64,
    provenance: i64,
) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO credit (subject_kind, subject_id, agent_id, role, provenance_id, rev) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![kind as i64, subject, agent, role, provenance, rev],
    )?;
    Ok(())
}

/// Tags read from local files are claims like any other, from one source.
fn local_tags_provenance(tx: &Transaction<'_>) -> rusqlite::Result<i64> {
    if let Some(id) = tx
        .query_row("SELECT id FROM provenance WHERE source = 'local_tags' AND external_ref IS NULL", [], |r| r.get(0))
        .optional()?
    {
        return Ok(id);
    }
    tx.query_row(
        "INSERT INTO provenance (source, fetched_at) VALUES ('local_tags', ?1) RETURNING id",
        [now_ms()],
        |r| r.get(0),
    )
}

fn head_hash(path: &Path) -> Option<Vec<u8>> {
    let mut buf = Vec::with_capacity(HEAD);
    std::fs::File::open(path).ok()?.take(HEAD as u64).read_to_end(&mut buf).ok()?;
    Some(blake3::hash(&buf).as_bytes().to_vec())
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use lofty::config::WriteOptions;
    use lofty::prelude::*;
    use lofty::tag::Tag;
    use meret_model::TrackId;

    const TONE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/meret/test/fixtures/tone-16-44.flac");

    fn put(dir: &Path, rel: &str, tags: Option<(&str, &str, &str, u32)>) {
        let path = dir.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::copy(TONE, &path).unwrap();
        if let Some((title, artist, album, n)) = tags {
            let mut tag = Tag::new(lofty::tag::TagType::VorbisComments);
            tag.set_title(title.into());
            tag.set_artist(artist.into());
            tag.set_album(album.into());
            tag.set_track(n);
            tag.save_to_path(&path, WriteOptions::default()).unwrap();
        } else {
            let mut file = lofty::read_from_path(&path).unwrap();
            let tag = file.primary_tag_mut().unwrap();
            tag.clear();
            tag.save_to_path(&path, WriteOptions::default()).unwrap();
        }
    }

    fn library() -> (PathBuf, Store) {
        let n = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("meret-ingest-{n}"));
        std::fs::create_dir_all(dir.join("music")).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        (dir, store)
    }

    fn track_at(store: &Store, path: &Path) -> Option<TrackId> {
        let cols = store.load_columns().unwrap();
        let rows = store.track_rows(&cols.track).unwrap();
        rows.into_iter().find(|r| r.path.as_deref() == Some(&*path.to_string_lossy())).map(|r| r.track)
    }

    #[test]
    fn a_scan_writes_tracks_in_album_order_and_a_rescan_writes_nothing() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "Iona/Open Sky/02.flac", Some(("Woman Of Wisdom", "Iona", "Open Sky", 2)));
        put(&music, "Iona/Open Sky/01.flac", Some(("Open Sky", "Iona", "Open Sky", 1)));
        put(&music, "Loose/untagged.flac", None);
        std::fs::write(music.join("Loose/notes.cue"), "not audio").unwrap();

        let root = add_root(&store, &music).unwrap();
        assert_eq!(add_root(&store, &music).unwrap(), root, "adding a folder twice finds the same root");
        let first = scan(&store, root, &|_| {}).unwrap();
        assert_eq!((first.found, first.added, first.unreadable), (4, 4, 1));

        let cols = store.load_columns().unwrap();
        let rows = store.track_rows(&cols.track).unwrap();
        let titles: Vec<_> = rows.iter().map(|r| (r.title.as_str(), r.album.as_str(), r.number)).collect();
        assert_eq!(titles, [("Open Sky", "Open Sky", 1), ("Woman Of Wisdom", "Open Sky", 2), ("untagged", "Loose", 0)]);
        assert_eq!(rows[0].release, rows[1].release, "one release for the album");
        assert_eq!(rows[0].artist.as_deref(), Some("Iona"));
        assert_eq!(rows[0].codec.as_deref(), Some("FLAC"));
        assert!(rows[0].path.as_deref().unwrap().ends_with("Iona/Open Sky/01.flac"));

        // Only the unreadable sheet is tried again.
        let again = scan(&store, root, &|_| {}).unwrap();
        assert_eq!((again.added, again.changed, again.moved, again.removed, again.unreadable), (1, 0, 0, 0, 1));
        assert_eq!(store.load_columns().unwrap().len(), 3);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_moved_file_keeps_its_track_and_a_removed_one_leaves_the_table() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "a/1.flac", Some(("One", "Hogg", "First", 1)));
        put(&music, "a/2.flac", Some(("Two", "Hogg", "First", 2)));
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();
        let before = track_at(&store, &music.canonicalize().unwrap().join("a/1.flac")).unwrap();

        std::fs::create_dir_all(music.join("b")).unwrap();
        std::fs::rename(music.join("a/1.flac"), music.join("b/1.flac")).unwrap();
        std::fs::remove_file(music.join("a/2.flac")).unwrap();
        let report = scan(&store, root, &|_| {}).unwrap();
        assert_eq!((report.moved, report.removed, report.added), (1, 1, 0));
        assert_eq!(track_at(&store, &music.canonicalize().unwrap().join("b/1.flac")), Some(before));
        assert_eq!(store.load_columns().unwrap().len(), 1);

        // Back again: the missing file's row comes back, with its track.
        put(&music, "a/2.flac", Some(("Two", "Hogg", "First", 2)));
        let report = scan(&store, root, &|_| {}).unwrap();
        assert_eq!(report.added, 1);
        assert_eq!(store.load_columns().unwrap().len(), 2);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_move_onto_a_missing_files_path_leaves_one_row() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "x.flac", Some(("X", "A", "Z", 1)));
        put(&music, "y.flac", Some(("Y", "A", "Z", 2)));
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();
        std::fs::remove_file(music.join("y.flac")).unwrap();
        scan(&store, root, &|_| {}).unwrap();

        std::fs::rename(music.join("x.flac"), music.join("y.flac")).unwrap();
        scan(&store, root, &|_| {}).unwrap();
        let cols = store.load_columns().unwrap();
        let rows = store.track_rows(&cols.track).unwrap();
        assert_eq!(rows.len(), 1, "no phantom row for the old path");
        assert!(rows[0].path.as_deref().unwrap().ends_with("/y.flac"));
        assert_eq!(rows[0].title, "X");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn an_unmounted_root_goes_offline_and_keeps_its_tracks() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "x.flac", Some(("X", "Y", "Z", 1)));
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();
        std::fs::rename(&music, dir.join("unplugged")).unwrap();
        assert!(scan(&store, root, &|_| {}).unwrap().offline);
        assert!(!roots(&store).unwrap()[0].online);
        assert_eq!(store.load_columns().unwrap().len(), 1);
        std::fs::remove_dir_all(dir).ok();
    }
}
