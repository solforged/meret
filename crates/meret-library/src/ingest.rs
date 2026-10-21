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

use meret_model::{EntityKind, Idiom, RootId};
use meret_store::{Store, StoreError, next_rev, search};
use rayon::prelude::*;
use rusqlite::{OptionalExtension, Transaction, params};

use crate::diff::diff;
use crate::tags::{Tags, read_tags};
use crate::walk::{FileStat, Walk, walk};

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
    ReadingCovers,
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
    /// Folders the walk couldn't list, relative to the root; their files were left as they were.
    pub unlisted: Vec<String>,
    /// The root wasn't there; it was marked offline and nothing changed.
    pub offline: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Root {
    pub id: RootId,
    pub path: PathBuf,
    pub online: bool,
    pub tracks: u64,
    pub label: String,
}

/// Adds a folder as a root, restoring a removed root at the same path.
pub fn add_root(store: &Store, path: &Path) -> Result<RootId, ScanError> {
    let path = path.canonicalize()?;
    let label = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "/".into());
    let text = path.to_string_lossy().into_owned();
    let id = store.writer.write(move |tx| {
        tx.execute(
            "INSERT INTO root (label, path, kind) VALUES (?1, ?2, 'local')
             ON CONFLICT(path) DO UPDATE SET state = 'online', label = excluded.label",
            params![label, text],
        )?;
        tx.query_row("SELECT id FROM root WHERE path = ?1", [&text], |r| r.get(0))
    })?;
    Ok(RootId(id))
}

/// Removes a root from the library without deleting its files or stored rows.
pub fn remove_root(store: &Store, root: RootId) -> Result<(), ScanError> {
    let changed = store.writer.write(move |tx| {
        tx.execute("UPDATE root SET state = 'removed' WHERE id = ?1", [root.0])
    })?;
    if changed == 0 {
        return Err(ScanError::NoRoot(root.0));
    }
    Ok(())
}

pub fn roots(store: &Store) -> Result<Vec<Root>, ScanError> {
    Ok(store.read(|c| {
        let mut stmt = c.prepare(
            "SELECT r.id, r.path, r.state, r.label,
                    (SELECT COUNT(DISTINCT s.track_id) FROM source s JOIN file f ON f.id = s.file_id
                     WHERE f.root_id = r.id AND f.state = 'present' AND s.kind = 'file')
             FROM root r WHERE r.state <> 'removed' ORDER BY r.id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Root {
                id: RootId(r.get(0)?),
                path: PathBuf::from(r.get::<_, String>(1)?),
                online: r.get::<_, String>(2)? == "online",
                label: r.get(3)?,
                tracks: r.get::<_, i64>(4)? as u64,
            })
        })?;
        rows.collect()
    })?)
}

/// Walks `root`, diffs it against the store, and writes what changed.
/// Blocks; call it from a background thread, never an engine thread.
pub fn scan(store: &Store, root: RootId, progress: &(dyn Fn(ScanProgress) + Sync)) -> Result<ScanReport, ScanError> {
    scan_in(store, root, &[], progress)
}

/// Walks only these folders of `root` and everything under them (relative,
/// `/`-separated, as `watch::plan` gives them), leaving the rest of the root
/// as the store has it.
pub fn rescan_dirs(store: &Store, root: RootId, dirs: &[String], progress: &(dyn Fn(ScanProgress) + Sync)) -> Result<ScanReport, ScanError> {
    if dirs.is_empty() {
        return Ok(ScanReport::default());
    }
    scan_in(store, root, dirs, progress)
}

/// The whole root when `dirs` is empty.
fn scan_in(store: &Store, root: RootId, dirs: &[String], progress: &(dyn Fn(ScanProgress) + Sync)) -> Result<ScanReport, ScanError> {
    let dir: Option<String> =
        store.read(|c| c.query_row("SELECT path FROM root WHERE id = ?1 AND state <> 'removed'", [root.0], |r| r.get(0)).optional())?;
    let dir = PathBuf::from(dir.ok_or(ScanError::NoRoot(root.0))?);
    let mut report = ScanReport::default();

    if !dir.is_dir() {
        store.writer.write(move |tx| tx.execute("UPDATE root SET state = 'offline' WHERE id = ?1", [root.0]))?;
        report.offline = true;
        return Ok(report);
    }

    // Taken before the walk, so a change made during it is replayed later.
    let whole = dirs.is_empty();
    #[cfg(target_os = "macos")]
    let mark = whole.then(|| crate::watch::database_uuid(&dir).map(|uuid| (crate::watch::current_event_id(), uuid))).flatten();
    #[cfg(not(target_os = "macos"))]
    let mark: Option<(u64, String)> = None;

    progress(ScanProgress { phase: Phase::Walking, done: 0, total: 0 });
    let seen: Walk = if whole {
        walk(&dir)
    } else {
        let mut all = Walk::default();
        for sub in dirs {
            let w = walk(&dir.join(sub));
            let under = |rel: String| if rel.is_empty() { sub.clone() } else { format!("{sub}/{rel}") };
            all.files.extend(w.files.into_iter().map(|mut f| {
                f.rel_path = under(std::mem::take(&mut f.rel_path));
                f
            }));
            all.unreadable.extend(w.unreadable.into_iter().map(under));
        }
        all
    };
    let found = &seen.files;
    report.found = found.len();
    let mut known = store.read(|c| {
        let row = |r: &rusqlite::Row<'_>| Ok(FileStat {
            rel_path: r.get(0)?,
            size: r.get::<_, i64>(1)? as u64,
            mtime_ns: r.get::<_, i64>(2)? as i128,
            inode: r.get::<_, Option<i64>>(3)?.map(|i| i as u64),
        });
        if whole {
            let mut stmt =
                c.prepare("SELECT rel_path, size, mtime_ns, inode FROM file WHERE root_id = ?1 AND state = 'present'")?;
            return stmt.query_map([root.0], row)?.collect::<rusqlite::Result<Vec<_>>>();
        }
        // Everything under `sub/`: from "sub/" up to "sub0", '0' following '/'.
        let mut stmt = c.prepare("SELECT rel_path, size, mtime_ns, inode FROM file
            WHERE root_id = ?1 AND state = 'present' AND rel_path >= ?2 AND rel_path < ?3")?;
        let mut known = vec![];
        for sub in dirs {
            known.extend(stmt.query_map(params![root.0, format!("{sub}/"), format!("{sub}0")], row)?.collect::<rusqlite::Result<Vec<_>>>()?);
        }
        Ok(known)
    })?;
    // A folder the walk couldn't list says nothing about its files: they stay as they were.
    if !seen.unreadable.is_empty() {
        report.unlisted = seen.unreadable.clone();
        known.retain(|f| !seen.unseen(&f.rel_path));
    }
    let d = diff(&known, found);

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

    store.writer.write(move |tx| match (whole, mark) {
        (true, Some((id, uuid))) => tx.execute(
            "UPDATE root SET state = 'online', last_walk_at = ?2, fsevents_id = ?3, fsevents_uuid = ?4 WHERE id = ?1",
            params![root.0, now_ms(), id as i64, uuid]),
        (true, None) => tx.execute("UPDATE root SET state = 'online', last_walk_at = ?2 WHERE id = ?1", params![root.0, now_ms()]),
        (false, _) => tx.execute("UPDATE root SET state = 'online' WHERE id = ?1", [root.0]),
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
    let title = meret_store::copies::clean_title(&title, t.track.unwrap_or(0));
    let album = t.album.clone().unwrap_or_else(|| {
        rel.parent()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| root_label.to_owned())
    });
    let artist = crate::splitting::people(t.artist.as_deref(), &t.artists);
    let album_written = t.album_artist.as_deref().or(t.artist.as_deref());
    let album_artists = if t.album_artist.is_some() || !t.album_artists.is_empty() {
        crate::splitting::people(t.album_artist.as_deref(), &t.album_artists)
    } else {
        artist.clone()
    };
    let release = release(tx, &album, album_written, &album_artists, t.year, rev, provenance)?;
    set_idiom(tx, release, crate::idiom::signal(&stat.rel_path, &t), rev)?;
    let medium = medium(tx, release, t.disc.unwrap_or(1), rev)?;
    tx.execute(
        "UPDATE release SET art_checked = 0 WHERE id = ?1 AND art_checked = 1
         AND NOT EXISTS (SELECT 1 FROM entity_artwork WHERE entity_kind = 3 AND entity_id = ?1)",
        [release],
    )?;
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
            let (track, recording) = match meret_store::copies::matching_track(tx, medium, t.track.unwrap_or(0), title, length)? {
                Some(ids) => ids,
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
                    (track, recording)
                }
            };
            let source: i64 = tx.query_row(
                "INSERT INTO source (recording_id, track_id, kind, file_id, rev) VALUES (?1, ?2, 'file', ?3, ?4) RETURNING id",
                params![recording, track, file, rev],
                |r| r.get(0),
            )?;
            (source, recording)
        }
    };
    tx.execute(
        "UPDATE source SET codec = ?2, sample_rate = ?3, bits = ?4, channels = ?5, lossless = ?6, length_ms = ?7, rev = ?8,
             bitrate_kbps = ?9 WHERE id = ?1",
        params![source, t.codec, t.sample_rate, t.bits, t.channels, t.lossless, length, rev, t.bitrate_kbps],
    )?;
    tx.execute("UPDATE recording SET artist_credit = ?2 WHERE id = ?1", params![recording, t.artist])?;
    credit_people(tx, EntityKind::Recording, recording, &artist, "artist", rev, provenance)?;
    for role in &t.credits {
        credit(tx, EntityKind::Recording, recording, &crate::splitting::role_people(&role.values), role.role, rev, provenance)?;
    }
    let work = work(tx, &t, rev, provenance)?;
    tx.execute("UPDATE recording SET work_id = ?2 WHERE id = ?1", params![recording, work])?;
    if t.label.is_some() || t.catalog_number.is_some() {
        tx.execute(
            "UPDATE edition SET label = COALESCE(label, ?2), catalog_no = COALESCE(catalog_no, ?3)
             WHERE release_id = ?1 AND is_default = 1",
            params![release, t.label, t.catalog_number],
        )?;
    }
    external_ids(tx, &t, recording, release, work, &artist, &album_artists, rev)?;
    search::index_recording(tx, recording)
}

/// A recording's work: the WORK tag, and a movement within it when MOVEMENTNAME
/// is set. The work's composer is ORIGINAL_COMPOSER when the file has one,
/// since then COMPOSER names whoever wrote this arrangement.
fn work(tx: &Transaction<'_>, t: &Tags, rev: i64, provenance: i64) -> rusqlite::Result<Option<i64>> {
    let Some(title) = &t.work else { return Ok(None) };
    let composers: Vec<String> = match &t.original_composer {
        Some(original) => vec![original.clone()],
        None => t.credits.iter().filter(|c| c.role == "composer").flat_map(|c| c.values.clone()).collect(),
    };
    let written = (!composers.is_empty()).then(|| composers.join("; "));
    let find_or_add = |title: &str, parent: Option<i64>, position: Option<u32>| -> rusqlite::Result<i64> {
        let found: Option<i64> = tx
            .query_row(
                "SELECT id FROM work WHERE title = ?1 AND parent_id IS ?2 AND composer_credit IS ?3 LIMIT 1",
                params![title, parent, written],
                |r| r.get(0),
            )
            .optional()?;
        match found {
            Some(id) => Ok(id),
            None => tx.query_row(
                "INSERT INTO work (parent_id, position, title, composer_credit, rev) VALUES (?1, ?2, ?3, ?4, ?5) RETURNING id",
                params![parent, position, title, written, rev],
                |r| r.get(0),
            ),
        }
    };
    let id = find_or_add(title, None, None)?;
    tx.execute(
        "DELETE FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND provenance_id = ?3",
        params![EntityKind::Work as i64, id, provenance],
    )?;
    credit(tx, EntityKind::Work, id, &crate::splitting::role_people(&composers), "composer", rev, provenance)?;
    match &t.movement {
        Some(movement) => find_or_add(movement, Some(id), t.movement_number).map(Some),
        None => Ok(Some(id)),
    }
}

/// MusicBrainz IDs and ISRCs, kept for lookups. An artist ID is kept only
/// when the tag has one per person, so it can't land on the wrong one.
#[allow(clippy::too_many_arguments)]
fn external_ids(
    tx: &Transaction<'_>,
    t: &Tags,
    recording: i64,
    release: i64,
    work: Option<i64>,
    artists: &[String],
    album_artists: &[String],
    rev: i64,
) -> rusqlite::Result<()> {
    let mut ids: Vec<(EntityKind, i64, &str, &str)> = vec![];
    if let Some(v) = &t.mb_recording { ids.push((EntityKind::Recording, recording, "mbid", v)); }
    if let Some(v) = &t.isrc { ids.push((EntityKind::Recording, recording, "isrc", v)); }
    if let Some(v) = &t.mb_release { ids.push((EntityKind::Release, release, "mbid", v)); }
    if let Some(v) = &t.mb_release_group { ids.push((EntityKind::Release, release, "mb_release_group", v)); }
    if let (Some(v), Some(work)) = (&t.mb_work, work) { ids.push((EntityKind::Work, work, "mbid", v)); }
    let mut agents = vec![];
    for (names, mbids) in [(artists, &t.mb_artists), (album_artists, &t.mb_album_artists)] {
        if names.len() == mbids.len() {
            for (name, mbid) in names.iter().zip(mbids) {
                agents.push((meret_store::credits::agent(tx, name, rev)?, mbid.as_str()));
            }
        }
    }
    ids.extend(agents.iter().map(|(agent, mbid)| (EntityKind::Agent, *agent, "mbid", *mbid)));
    for (kind, id, namespace, value) in ids {
        tx.execute(
            "INSERT OR IGNORE INTO external_id (entity_kind, entity_id, namespace, value) VALUES (?1, ?2, ?3, ?4)",
            params![kind as i64, id, namespace, value],
        )?;
    }
    Ok(())
}

/// A release is its title and album artist, as tagged.
fn release(
    tx: &Transaction<'_>,
    title: &str,
    album_written: Option<&str>,
    album_artists: &[String],
    year: Option<u16>,
    rev: i64,
    provenance: i64,
) -> rusqlite::Result<i64> {
    let found: Option<i64> = tx
        .query_row(
            "SELECT rl.id FROM release rl
             WHERE rl.title = ?1 AND rl.album_artist_credit IS ?2 LIMIT 1",
            params![title, album_written],
            |r| r.get(0),
        )
        .optional()?;
    let id = if let Some(id) = found {
        if year.is_some() {
            tx.execute("UPDATE release SET year = ?2 WHERE id = ?1 AND year IS NULL", params![id, year])?;
        }
        tx.execute("DELETE FROM credit WHERE subject_kind = 3 AND subject_id = ?1 AND role = 'album_artist' AND provenance_id = ?2",
            params![id, provenance])?;
        id
    } else {
        let id: i64 = tx.query_row(
            "INSERT INTO release (title, year, album_artist_credit, rev) VALUES (?1, ?2, ?3, ?4) RETURNING id",
            params![title, year, album_written, rev],
            |r| r.get(0),
        )?;
        tx.execute("INSERT INTO edition (release_id, is_default, rev) VALUES (?1, 1, ?2)", params![id, rev])?;
        id
    };
    credit_people(tx, EntityKind::Release, id, album_artists, "album_artist", rev, provenance)?;
    search::index_release(tx, id)?;
    Ok(id)
}

/// Gives a release its first idiom: what a file's signal says, or Album
/// when nothing does. A signal replaces the default, never another signal
/// or your choice, so the first file that says something decides.
fn set_idiom(tx: &Transaction<'_>, release: i64, signal: Option<(Idiom, &str)>, rev: i64) -> rusqlite::Result<()> {
    use crate::idiom::source;
    match signal {
        Some((idiom, from)) => tx.execute(
            "UPDATE release SET idiom = ?2, idiom_source = ?3, rev = ?4
             WHERE id = ?1 AND (idiom IS NULL OR idiom_source = ?5)",
            params![release, idiom as u8, from, rev, source::DEFAULT],
        )?,
        None => tx.execute(
            "UPDATE release SET idiom = ?2, idiom_source = ?3, rev = ?4 WHERE id = ?1 AND idiom IS NULL",
            params![release, Idiom::Album as u8, source::DEFAULT, rev],
        )?,
    };
    Ok(())
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

fn credit_people(
    tx: &Transaction<'_>,
    kind: EntityKind,
    subject: i64,
    names: &[String],
    role: &str,
    rev: i64,
    provenance: i64,
) -> rusqlite::Result<()> {
    let people: Vec<(String, Option<String>)> = names.iter().map(|n| (n.clone(), None)).collect();
    credit(tx, kind, subject, &people, role, rev, provenance)
}

/// Credits each person in `role`, with a detail such as an instrument.
fn credit(
    tx: &Transaction<'_>,
    kind: EntityKind,
    subject: i64,
    people: &[(String, Option<String>)],
    role: &str,
    rev: i64,
    provenance: i64,
) -> rusqlite::Result<()> {
    for (sort, (name, detail)) in people.iter().enumerate() {
        let agent = meret_store::credits::agent(tx, name, rev)?;
        tx.execute(
            "INSERT INTO credit (subject_kind, subject_id, agent_id, role, detail, sort, provenance_id, rev)
             SELECT ?1, ?2, ?3, ?4, ?8, ?5, ?6, ?7 WHERE NOT EXISTS (
                SELECT 1 FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND agent_id = ?3 AND role = ?4 AND provenance_id = ?6)",
            params![kind as i64, subject, agent, role, sort as i64, provenance, rev, detail],
        )?;
    }
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
        // Tests run in parallel and can start in the same nanosecond.
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let t = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = std::env::temp_dir().join(format!("meret-ingest-{}-{t}-{n}", std::process::id()));
        std::fs::create_dir_all(dir.join("music")).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        (dir, store)
    }

    fn track_at(store: &Store, path: &Path) -> Option<TrackId> {
        let cols = store.load_columns().unwrap();
        let rows = store.track_rows(&cols.track).unwrap();
        rows.into_iter().find(|r| r.path.as_deref() == Some(&*path.to_string_lossy())).map(|r| r.track)
    }

    /// A tone with these Vorbis comments, any key included.
    fn put_comments(dir: &Path, rel: &str, comments: &[(&str, &str)]) {
        let path = dir.join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::copy(TONE, &path).unwrap();
        let mut tag = lofty::ogg::tag::VorbisComments::default();
        for (key, value) in comments {
            tag.push((*key).into(), (*value).into());
        }
        tag.save_to_path(&path, WriteOptions::default()).unwrap();
    }

    #[test]
    fn roles_and_works_from_tags_answer_queries_and_fill_pages() {
        let (dir, store) = library();
        let music = dir.join("music");
        let arranged = [("ALBUM", "Civ"), ("ARTIST", "Ada Vellum"), ("COMPOSER", "Ada Vellum"), ("WORK", "Ode to Joy"),
            ("ORIGINAL_COMPOSER", "Dora Klee")];
        put_comments(&music, "civ/09.flac", &[arranged.as_slice(), &[("TITLE", "Peace"), ("TRACKNUMBER", "9"),
            ("ARRANGER", "Bo Strand; not separately itemized in the consulted release metadata"),
            ("PERFORMER", "Cy Reed (ney)")]].concat());
        put_comments(&music, "civ/10.flac", &[arranged.as_slice(), &[("TITLE", "War"), ("TRACKNUMBER", "10")]].concat());
        put_comments(&music, "nine/4.flac", &[("ALBUM", "Ninth"), ("ARTIST", "Fen Orchestra"), ("TITLE", "Presto"),
            ("COMPOSER", "Dora Klee"), ("CONDUCTOR", "Eli Marsh"), ("WORK", "Symphony No. 9"), ("MOVEMENTNAME", "IV. Presto"),
            ("MOVEMENT", "4"), ("MUSICBRAINZ_WORKID", "w-4"), ("MUSICBRAINZ_TRACKID", "rec-4"), ("LABEL", "Fen Records")]);
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();

        let cols = store.load_columns().unwrap();
        let rows = |q: &str| {
            let meret_query::Input::Search(q) = meret_query::parse(q).unwrap() else { unreachable!() };
            store.answer_residual(meret_store::plan(&q, &cols, 0), &cols).unwrap().map(|r| r.len())
        };
        assert_eq!(rows("composer:klee"), Some(3), "the work's composer composed its arrangements and its movements");
        assert_eq!(rows("composer:vellum"), Some(2));
        assert_eq!(rows("arranged:strand"), Some(1));
        assert_eq!(rows("played:reed"), Some(1));
        assert_eq!(rows("performer:vellum"), Some(2), "the artist tag still says who performs");
        assert_eq!(rows("conducted:marsh"), Some(1));
        assert_eq!(rows("by:klee"), Some(3));
        assert_eq!(rows("klee"), Some(3), "work composers are searchable text");
        assert_eq!(rows("work:\"ode to joy\""), Some(2));
        assert_eq!(rows("work:symphony"), Some(1), "a movement is found by its work");

        let civ = store.release_hits(&["civ".into()], 1).unwrap().1[0].release;
        let page = store.release_page(civ).unwrap().unwrap();
        let roles: Vec<_> = page.roles.iter().map(|c| (c.role.as_str(), c.name.as_str(), c.detail.as_deref(), c.positions.clone())).collect();
        assert_eq!(roles, [
            ("composer", "Ada Vellum", None, vec![(1, 9), (1, 10)]),
            ("arranger", "Bo Strand", None, vec![(1, 9)]),
            ("performer", "Cy Reed", Some("ney"), vec![(1, 9)]),
        ], "a note in a credit tag names no one");
        assert_eq!(page.works.len(), 2);
        assert_eq!(page.works[0].1, page.works[1].1, "both arrangements record one work");

        let klee = store.people_hits(&["klee".into()], 1).unwrap().1[0].agent;
        let person = store.person_page(klee).unwrap().unwrap();
        assert_eq!(person.tracks, 3);
        assert_eq!(person.works.iter().map(|w| (w.title.as_str(), w.tracks)).collect::<Vec<_>>(), [("Ode to Joy", 2), ("Symphony No. 9", 1)]);
        assert_eq!(person.roles.iter().map(|(role, releases)| (role.as_str(), releases.len())).collect::<Vec<_>>(), [("composer", 1)]);

        let symphony = person.works[1].work;
        let work = store.work_page(symphony).unwrap().unwrap();
        assert_eq!(work.composers.iter().map(|(_, name)| name.as_str()).collect::<Vec<_>>(), ["Dora Klee"]);
        assert_eq!(work.parts.iter().map(|p| (p.title.as_str(), p.tracks)).collect::<Vec<_>>(), [("IV. Presto", 1)]);
        assert_eq!(work.tracks.len(), 1);
        let movement = store.work_page(work.parts[0].work).unwrap().unwrap();
        assert_eq!(movement.parent.map(|(_, title)| title).as_deref(), Some("Symphony No. 9"));
        assert_eq!(movement.composer.as_deref(), Some("Dora Klee"), "a movement's composer is its work's");

        let ids: Vec<(i64, String, String)> = store.read(|c| c.prepare("SELECT entity_kind, namespace, value FROM external_id ORDER BY value")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect()).unwrap();
        assert_eq!(ids, [(2, "mbid".to_string(), "rec-4".to_string()), (1, "mbid".into(), "w-4".into())]);

        // Rescanning changed files keeps one work and one set of credits.
        scan(&store, root, &|_| {}).unwrap();
        std::fs::remove_file(music.join("civ/10.flac")).unwrap();
        put_comments(&music, "civ/10.flac", &[arranged.as_slice(), &[("TITLE", "War"), ("TRACKNUMBER", "10")]].concat());
        scan(&store, root, &|_| {}).unwrap();
        assert_eq!(store.read(|c| c.query_row("SELECT COUNT(*) FROM work", [], |r| r.get::<_, i64>(0))).unwrap(), 3);
        assert_eq!(store.release_page(civ).unwrap().unwrap().roles.len(), 3);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn joint_people_keep_written_display_and_share_facets_pages_and_threads() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "joint/1.flac", Some(("Joint", "Roger Briggs & Mark Cromer", "Civilization III", 1)));
        put(&music, "joint/2.flac", Some(("Solo", "Mark Cromer", "Civilization III", 2)));
        for rel in ["joint/1.flac", "joint/2.flac"] {
            let path = music.join(rel);
            let mut file = lofty::read_from_path(&path).unwrap();
            file.primary_tag_mut().unwrap().insert_text(ItemKey::AlbumArtist, "Roger Briggs & Mark Cromer".into());
            file.save_to_path(&path, WriteOptions::default()).unwrap();
        }
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();
        let cols = store.load_columns().unwrap();
        let rows = store.track_rows(&cols.track).unwrap();
        assert_eq!(rows[0].artist.as_deref(), Some("Roger Briggs & Mark Cromer"));
        assert_eq!(rows[0].album_artist.as_deref(), Some("Roger Briggs & Mark Cromer"));
        assert_eq!(cols.people(0).len(), 2);
        assert_eq!(cols.people(1).len(), 2, "the same person in both roles counts once");
        let roger = store.people_hits(&["Roger".into()], 10).unwrap().1.remove(0);
        let mark = store.people_hits(&["Mark".into()], 10).unwrap().1.remove(0);
        assert_eq!((roger.tracks, mark.tracks), (2, 2));
        assert_eq!(store.tracks_by_person("Mark Cromer", None).unwrap().len(), 2);
        let page = store.release_page(rows[0].release).unwrap().unwrap();
        assert_eq!(page.album_artists.iter().map(|(_, n)| n.as_str()).collect::<Vec<_>>(), ["Roger Briggs", "Mark Cromer"]);
        assert_eq!(page.artists.iter().map(|a| (a.name.as_str(), a.positions.len())).collect::<Vec<_>>(), [("Roger Briggs", 1), ("Mark Cromer", 2)]);
        let person = store.person_page(mark.agent).unwrap().unwrap();
        assert_eq!((person.tracks, person.releases.len(), person.appears_on.len()), (2, 1, 0));
        assert_eq!(person.worked_with[0].name, "Roger Briggs");
        assert_eq!(store.read(|c| c.query_row("SELECT COUNT(*) FROM agent WHERE name LIKE '% & %'", [], |r| r.get::<_, u32>(0))).unwrap(), 0);
        std::fs::remove_dir_all(dir).unwrap();
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
    fn alternate_files_share_track_and_recording_and_rescan_keeps_ids() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "A/1.flac", Some(("1 - Terratus", "Composer", "Tyranny", 1)));
        put(&music, "B/1.flac", Some(("TÉRRA-tus!", "Composer", "Tyranny", 1)));
        put(&music, "B/2.flac", Some(("Terratus", "Composer", "Tyranny", 2)));
        // Filename fallback has tags for album and track, but no title.
        put(&music, "C/3 - Ending.flac", Some(("temporary", "Composer", "Tyranny", 3)));
        let path = music.join("C/3 - Ending.flac");
        let mut tagged = lofty::read_from_path(&path).unwrap();
        tagged.primary_tag_mut().unwrap().remove_key(ItemKey::TrackTitle);
        tagged.save_to_path(&path, WriteOptions::default()).unwrap();
        let root = add_root(&store, &music).unwrap();
        let first = scan(&store, root, &|_| {}).unwrap();
        assert_eq!((first.found, first.added, first.changed), (4, 4, 0));
        let ids: Vec<(i64, i64, i64)> = store.read(|c| c.prepare("SELECT id, track_id, recording_id FROM source ORDER BY id")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect()).unwrap();
        assert_eq!(ids.len(), 4);
        assert_eq!(store.load_columns().unwrap().len(), 3);
        let rows = store.track_rows(&store.load_columns().unwrap().track).unwrap();
        assert_eq!(rows[2].title, "Ending");
        let again = scan(&store, root, &|_| {}).unwrap();
        assert_eq!((again.found, again.added, again.changed, again.moved, again.removed), (4, 0, 0, 0, 0));
        let after: Vec<(i64, i64, i64)> = store.read(|c| c.prepare("SELECT id, track_id, recording_id FROM source ORDER BY id")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect()).unwrap();
        assert_eq!(ids, after);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_genre_on_any_file_outranks_the_album_default() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "x/1.flac", Some(("Opening", "Mitsuda", "Xenogears", 1)));
        put(&music, "x/2.flac", Some(("Ending", "Mitsuda", "Xenogears", 2)));
        put(&music, "w/1.flac", Some(("So What", "Davis", "Kind of Blue", 1)));
        put(&music, "p/1.flac", Some(("Glass", "Iona", "Open Sky", 1)));
        for (rel, genre) in [("x/2.flac", "Video Game Soundtrack"), ("w/1.flac", "Jazz")] {
            let path = music.join(rel);
            let mut file = lofty::read_from_path(&path).unwrap();
            file.primary_tag_mut().unwrap().set_genre(genre.into());
            file.save_to_path(&path, WriteOptions::default()).unwrap();
        }
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();

        let cols = store.load_columns().unwrap();
        let idioms: HashMap<String, Option<Idiom>> =
            store.track_rows(&cols.track).unwrap().into_iter().map(|r| (r.title, r.idiom)).collect();
        assert_eq!(idioms["Opening"], Some(Idiom::Score), "the release's other file said Score");
        assert_eq!(idioms["Ending"], Some(Idiom::Score));
        assert_eq!(idioms["So What"], Some(Idiom::Session));
        assert_eq!(idioms["Glass"], Some(Idiom::Album), "nothing said otherwise");

        // The Front counts releases, not tracks.
        let facts = store.library_facts(10).unwrap();
        assert_eq!(facts.releases_by_idiom[Idiom::Score as usize], 1);
        assert_eq!(facts.releases_by_idiom[Idiom::Album as usize], 1);
        assert_eq!(facts.added_lately.len(), 3);

        let rows = |q: &str| {
            let meret_query::Input::Search(q) = meret_query::parse(q).unwrap() else { unreachable!() };
            store.answer_residual(meret_store::plan(&q, &cols, 0), &cols).unwrap().map(|r| r.len())
        };
        assert_eq!(rows(r#"release:"xenogears""#), Some(2), "release names ignore case");
        assert_eq!(rows(r#"-release:Xenogears"#), Some(2));
        assert_eq!(rows("idiom:score"), Some(2));
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn text_people_and_names_filter_through_full_text_search() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "a/1.flac", Some(("Open Sky", "Iona", "Open Sky", 1)));
        put(&music, "a/2.flac", Some(("Woman Of Wisdom", "Iona", "Open Sky", 2)));
        put(&music, "b/1.flac", Some(("Isle of Iona", "Joanne Hogg", "Celtic", 1)));
        put(&music, "c/1.flac", Some(("Lark", "Iona Brown", "Ascending", 1)));
        put(&music, "d/1.flac", Some(("Prelude", "Víkingur Ólafsson", "Bach", 1)));
        put(&music, "e/1.flac", Some(("Saga", "Mikkel Bødtker", "Legend", 1)));
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();

        let cols = store.load_columns().unwrap();
        let rows = |q: &str| {
            let meret_query::Input::Search(q) = meret_query::parse(q).unwrap() else { unreachable!() };
            store.answer_residual(meret_store::plan(&q, &cols, 0), &cols).unwrap().map(|r| r.len())
        };
        assert_eq!(rows("iona"), Some(4), "by Iona, by Iona Brown, and a title");
        assert_eq!(rows("OLAFSSON"), Some(1), "case and accents fold");
        assert_eq!(rows("bod"), Some(1), "ø folds to o through the index too");
        assert_eq!(rows("bø"), Some(1));
        assert_eq!(rows("of"), Some(2), "a short word scans");
        assert_eq!(rows("iona of"), Some(2));
        assert_eq!(rows("iona -wisdom"), Some(3));
        assert_eq!(rows("by:iona"), Some(2), "an exact name excludes Iona Brown");
        assert_eq!(rows("by:ion"), Some(3), "without an exact name, contains matching remains");
        assert_eq!(rows("performer:hogg"), Some(1));
        assert_eq!(rows("release:sky"), Some(2));
        assert_eq!(rows("game:chrono"), Some(0), "nothing says what game a track is from yet");
        assert_eq!(rows("-game:chrono"), Some(6));

        let (total, people) = store.people_hits(&["iona".into()], 5).unwrap();
        assert_eq!(total, 2);
        assert_eq!(people.iter().map(|p| (p.name.as_str(), p.tracks)).collect::<Vec<_>>(), [("Iona", 2), ("Iona Brown", 1)]);
        let (total, releases) = store.release_hits(&["sky".into()], 5).unwrap();
        assert_eq!(total, 1);
        assert_eq!((releases[0].title.as_str(), releases[0].artist.as_deref(), releases[0].tracks), ("Open Sky", Some("Iona"), 2));
        let titled = store.tracks_titled(&["iona".into()]).unwrap();
        let titles: Vec<_> = store.track_rows(&titled.into_iter().collect::<Vec<_>>()).unwrap().into_iter().map(|r| r.title).collect();
        assert_eq!(titles, ["Isle of Iona"]);

        // A rescan that re-reads a file replaces its row rather than adding
        // one, and someone whose files have gone drops out of the hits.
        put(&music, "a/1.flac", Some(("Open Sky (live)", "Iona", "Open Sky", 1)));
        std::fs::remove_file(music.join("c/1.flac")).unwrap();
        scan(&store, root, &|_| {}).unwrap();
        let (total, people) = store.people_hits(&["iona".into()], 5).unwrap();
        assert_eq!((total, people.len()), (1, 1));
        let cols = store.load_columns().unwrap();
        let rows = |q: &str| {
            let meret_query::Input::Search(q) = meret_query::parse(q).unwrap() else { unreachable!() };
            store.answer_residual(meret_store::plan(&q, &cols, 0), &cols).unwrap().map(|r| r.len())
        };
        assert_eq!(rows("live"), Some(1));
        assert_eq!(rows("iona"), Some(3));
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn release_and_person_pages_follow_local_credits() {
        let (dir, store) = library();
        let music = dir.join("music");
        let tagged = |rel: &str, title: &str, artist: &str, album: &str, album_artist: &str, disc: u32, n: u32| {
            put(&music, rel, Some((title, artist, album, n)));
            let path = music.join(rel);
            let mut file = lofty::read_from_path(&path).unwrap();
            let tag = file.primary_tag_mut().unwrap();
            tag.insert_text(ItemKey::AlbumArtist, album_artist.into());
            tag.set_disk(disc);
            tag.save_to_path(&path, WriteOptions::default()).unwrap();
        };
        tagged("x/2-17.flac", "Small Two of Pieces", "Joanne Hogg", "Xenogears", "Yasunori Mitsuda", 2, 17);
        tagged("x/1-01.flac", "Opening", "Yasunori Mitsuda", "Xenogears", "Yasunori Mitsuda", 1, 1);
        tagged("x/2-16.flac", "Stars of Tears", "Joanne Hogg", "Xenogears", "Yasunori Mitsuda", 2, 16);
        tagged("h/1.flac", "Looking Into Light", "Joanne Hogg", "Looking Into Light", "Joanne Hogg", 1, 1);
        tagged("i/1.flac", "Open Sky", "Iona", "Open Sky", "Iona", 1, 1);
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();

        let rows = store.track_rows(&store.load_columns().unwrap().track).unwrap();
        let row = |title: &str| rows.iter().find(|r| r.title == title).unwrap().clone();
        let (xeno, hogg, mitsuda, iona) =
            (row("Opening").release, row("Stars of Tears").artist_id.unwrap(), row("Opening").artist_id.unwrap(), row("Open Sky").artist_id.unwrap());
        assert_eq!(row("Stars of Tears").album_artist_id, Some(mitsuda));

        let page = store.release_page(xeno).unwrap().unwrap();
        assert_eq!(page.album_artist, Some((mitsuda, "Yasunori Mitsuda".into())));
        let titles: Vec<_> = page.tracks.iter().map(|t| t.title.as_str()).collect();
        assert_eq!(titles, ["Opening", "Stars of Tears", "Small Two of Pieces"]);
        let credits: Vec<_> = page.artists.iter().map(|a| (a.name.as_str(), a.positions.clone())).collect();
        assert_eq!(credits, [("Yasunori Mitsuda", vec![(1, 1)]), ("Joanne Hogg", vec![(2, 16), (2, 17)])]);

        let hogg = store.person_page(hogg).unwrap().unwrap();
        assert_eq!(hogg.tracks, 3);
        let releases: Vec<_> = hogg.releases.iter().map(|r| (r.title.as_str(), r.theirs, r.tracks)).collect();
        assert_eq!(releases, [("Looking Into Light", 1, 1)]);
        let on: Vec<_> = hogg.appears_on.iter().map(|r| (r.title.as_str(), r.theirs, r.tracks)).collect();
        assert_eq!(on, [("Xenogears", 2, 3)]);
        let with: Vec<_> = hogg.worked_with.iter().map(|c| (c.name.as_str(), c.releases)).collect();
        assert_eq!(with, [("Yasunori Mitsuda", 1)]);

        let iona = store.person_page(iona).unwrap().unwrap();
        assert_eq!((iona.releases.len(), iona.appears_on.len(), iona.worked_with.len()), (1, 0, 0));
        assert_eq!(store.release_page(meret_model::ReleaseId(9_999)).unwrap(), None);
        assert_eq!(store.agent_name(mitsuda).unwrap().as_deref(), Some("Yasunori Mitsuda"));
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

    #[cfg(unix)]
    #[test]
    fn a_folder_the_walk_cannot_list_keeps_its_files() {
        use std::os::unix::fs::PermissionsExt;
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "open/1.flac", Some(("One", "Hogg", "First", 1)));
        put(&music, "shut/2.flac", Some(("Two", "Hogg", "First", 2)));
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();

        // As macOS refuses ~/Music/Music to an app without Media & Apple Music access.
        std::fs::set_permissions(music.join("shut"), std::fs::Permissions::from_mode(0o000)).unwrap();
        let whole = scan(&store, root, &|_| {}).unwrap();
        let some = rescan_dirs(&store, root, &["shut".into()], &|_| {}).unwrap();
        std::fs::set_permissions(music.join("shut"), std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!((whole.removed, whole.unlisted.as_slice()), (0, ["shut".to_string()].as_slice()));
        assert_eq!((some.removed, some.unlisted.as_slice()), (0, ["shut".to_string()].as_slice()));
        assert_eq!(store.load_columns().unwrap().len(), 2);

        // Listed again, a file that really went is still found missing.
        std::fs::remove_file(music.join("shut/2.flac")).unwrap();
        assert_eq!(scan(&store, root, &|_| {}).unwrap().removed, 1);
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
    fn rescanning_folders_touches_only_them_and_follows_a_move_between_them() {
        let (dir, store) = library();
        let music = dir.join("music");
        put(&music, "a/1.flac", Some(("One", "Hogg", "First", 1)));
        put(&music, "a/2.flac", Some(("Two", "Hogg", "First", 2)));
        put(&music, "a b/4.flac", Some(("Four", "Hogg", "Beside", 1)));
        put(&music, "b/3.flac", Some(("Three", "Hogg", "Second", 1)));
        let root = add_root(&store, &music).unwrap();
        scan(&store, root, &|_| {}).unwrap();
        let canonical = music.canonicalize().unwrap();
        let one = track_at(&store, &canonical.join("a/1.flac")).unwrap();
        if cfg!(target_os = "macos") {
            let mark = &crate::watch::marks(&store).unwrap()[0];
            assert!(mark.id.is_some() && mark.uuid.is_some(), "a full walk records where FSEvents can resume");
        }

        std::fs::create_dir_all(music.join("c")).unwrap();
        std::fs::rename(music.join("a/1.flac"), music.join("c/1.flac")).unwrap();
        put(&music, "c/5.flac", Some(("Five", "Hogg", "Third", 1)));
        std::fs::remove_file(music.join("b/3.flac")).unwrap();
        std::fs::remove_file(music.join("a b/4.flac")).unwrap();
        let report = rescan_dirs(&store, root, &["a".into(), "c".into()], &|_| {}).unwrap();
        assert_eq!((report.moved, report.added, report.removed), (1, 1, 0));
        assert_eq!(track_at(&store, &canonical.join("c/1.flac")), Some(one));
        assert!(track_at(&store, &canonical.join("a/2.flac")).is_some());
        assert!(track_at(&store, &canonical.join("b/3.flac")).is_some(), "b wasn't asked about");
        assert!(track_at(&store, &canonical.join("a b/4.flac")).is_some(), "\"a b\" sorts beside \"a\" but isn't under it");

        let report = rescan_dirs(&store, root, &["b".into()], &|_| {}).unwrap();
        assert_eq!(report.removed, 1);
        assert_eq!(store.load_columns().unwrap().len(), 4);
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
