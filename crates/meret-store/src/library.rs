//! Reads over the library: the hot columns at start-up and after a scan,
//! and full rows for the few tracks a table page or a queue needs.

use std::collections::{HashMap, HashSet};

use meret_model::{Idiom, RecordingId, ReleaseId, TrackId};
use meret_query::{NameField, Term};
use roaring::RoaringBitmap;
use rusqlite::Connection;

use crate::columns::{HotColumns, Row};
use crate::plan::{Plan, format_code};
use crate::{Result, Store};

/// One track as the table draws it and the queue plays it.
#[derive(Clone, Debug, PartialEq)]
pub struct TrackRow {
    pub track: TrackId,
    pub recording: RecordingId,
    pub release: ReleaseId,
    pub idiom: Option<Idiom>,
    pub title: String,
    pub artist: Option<String>,
    pub album: String,
    pub album_artist: Option<String>,
    pub disc: u32,
    pub number: u32,
    pub year: Option<u16>,
    pub length_ms: Option<u64>,
    /// "FLAC", "ALAC", "AAC", "MP3"…
    pub codec: Option<String>,
    pub sample_rate: Option<u32>,
    pub bits: Option<u8>,
    /// The file to play, if one is present.
    pub path: Option<String>,
}

/// The album artist a release is sorted under.
const ALBUM_ARTIST: &str = "(SELECT COALESCE(a.sort_name, a.name) FROM credit c JOIN agent a ON a.id = c.agent_id
    WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1)";

/// The source a track plays from and is counted by: a present file,
/// lossless first. Both reads use it, so a row matches what it shows.
const PREFERRED_SOURCE: &str = "(SELECT s2.id FROM source s2 JOIN file f2 ON f2.id = s2.file_id
    WHERE s2.track_id = t.id AND s2.kind = 'file' AND f2.state = 'present' ORDER BY s2.lossless DESC, s2.id LIMIT 1)";

impl Store {
    /// Builds the hot columns from SQLite: one row per track with a present
    /// file, in library order (album artist, unknown last; album; disc;
    /// track), so a result's row numbers are already sorted.
    pub fn load_columns(&self) -> Result<HotColumns> {
        self.read(|c| {
            let sql = format!(
                "SELECT t.id, COALESCE(rl.year, 0), COALESCE(t.length_ms, r.length_ms, 0),
                        COALESCE(l.plays, 0), COALESCE(l.last, 0), COALESCE(f.added_at, 0),
                        COALESCE(e.dr, 0), COALESCE(rl.idiom, 0),
                        s.codec, s.sample_rate, s.bits, s.lossless, {ALBUM_ARTIST} AS album_artist
                 FROM track t
                 JOIN recording r ON r.id = t.recording_id
                 JOIN medium m ON m.id = t.medium_id
                 JOIN edition e ON e.id = m.edition_id
                 JOIN release rl ON rl.id = e.release_id
                 JOIN source s ON s.id = {PREFERRED_SOURCE}
                 JOIN file f ON f.id = s.file_id
                 LEFT JOIN (SELECT recording_id, COUNT(*) AS plays, MAX(started_at) AS last
                            FROM listen GROUP BY recording_id) l ON l.recording_id = t.recording_id
                 ORDER BY album_artist IS NULL, album_artist COLLATE NOCASE, rl.title COLLATE NOCASE, rl.id,
                          m.position, t.position, f.rel_path"
            );
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map([], |r| {
                let codec: Option<String> = r.get(8)?;
                let rate: Option<u32> = r.get(9)?;
                let bits: Option<u8> = r.get(10)?;
                let lossless: bool = r.get(11)?;
                Ok(Row {
                    track: r.get(0)?,
                    year: r.get(1)?,
                    length_s: (r.get::<_, i64>(2)? / 1000) as u32,
                    plays: r.get(3)?,
                    last_played: r.get::<_, i64>(4)? / 1000,
                    added: r.get::<_, i64>(5)? / 1000,
                    dr: r.get(6)?,
                    idiom: r.get(7)?,
                    format: format_code::classify(codec.as_deref(), rate, bits, lossless),
                    availability: if lossless { 0 } else { 1 },
                    guessed: false,
                })
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>().map(HotColumns::from_rows)
        })
    }

    /// Full rows for `tracks`, in the order asked for. Tracks that no
    /// longer exist are left out.
    pub fn track_rows(&self, tracks: &[TrackId]) -> Result<Vec<TrackRow>> {
        let mut found: HashMap<TrackId, TrackRow> = HashMap::with_capacity(tracks.len());
        self.read(|c| {
            for chunk in tracks.chunks(500) {
                read_rows(c, chunk, &mut found)?;
            }
            Ok(())
        })?;
        Ok(tracks.iter().filter_map(|t| found.remove(t)).collect())
    }

    /// What the Front says about the library that the hot columns can't:
    /// releases per idiom, what arrived lately, and what needs you.
    pub fn library_facts(&self, recent: usize) -> Result<LibraryFacts> {
        self.read(|c| {
            let mut facts = LibraryFacts::default();
            let sql = format!(
                "SELECT COALESCE(rl.idiom, 0), COUNT(DISTINCT rl.id) FROM release rl
                 JOIN edition e ON e.release_id = rl.id JOIN medium m ON m.edition_id = e.id
                 JOIN track t ON t.medium_id = m.id
                 WHERE {PREFERRED_SOURCE} IS NOT NULL GROUP BY 1"
            );
            for row in c.prepare(&sql)?.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))? {
                let (idiom, n) = row?;
                if let Some(slot) = facts.releases_by_idiom.get_mut(idiom as usize) {
                    *slot = n as u64;
                }
            }

            let sql = format!(
                "SELECT rl.id, rl.title,
                        (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                         WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1),
                        rl.year, COUNT(*), MAX(COALESCE(f.added_at, 0)) AS added
                 FROM release rl
                 JOIN edition e ON e.release_id = rl.id JOIN medium m ON m.edition_id = e.id
                 JOIN track t ON t.medium_id = m.id
                 JOIN source s ON s.id = {PREFERRED_SOURCE}
                 JOIN file f ON f.id = s.file_id
                 GROUP BY rl.id ORDER BY added DESC, rl.id DESC LIMIT ?1"
            );
            facts.added_lately = c
                .prepare(&sql)?
                .query_map([recent as i64], |r| {
                    Ok(RecentRelease {
                        release: ReleaseId(r.get(0)?),
                        title: r.get(1)?,
                        artist: r.get(2)?,
                        year: r.get(3)?,
                        tracks: r.get(4)?,
                        added_ms: r.get(5)?,
                    })
                })?
                .collect::<rusqlite::Result<_>>()?;

            for row in c.prepare("SELECT state, COUNT(*) FROM file GROUP BY state")?.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))
            })? {
                match row? {
                    (s, n) if s == "unreadable" => facts.unreadable = n,
                    (s, n) if s == "missing" => facts.missing = n,
                    _ => {}
                }
            }

            let sql = format!(
                "SELECT COUNT(*) FROM track t WHERE {PREFERRED_SOURCE} IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM credit c WHERE c.subject_kind = 2 AND c.subject_id = t.recording_id AND c.role = 'artist')"
            );
            facts.no_artist = c.query_row(&sql, [], |r| r.get::<_, i64>(0))? as u64;
            Ok(facts)
        })
    }

    /// The rows `plan` matches, once the clauses it left for SQL are
    /// applied: free text, people and release names through full-text
    /// search. Nothing in the library answers the other clauses yet
    /// (games, films, labels, works, wants, BPM), so they match nothing.
    pub fn answer_residual(&self, plan: Plan, cols: &HotColumns) -> Result<Option<RoaringBitmap>> {
        // Free-text words that aren't negated are one search, so a short word
        // only scans what the longer ones found.
        let words: Vec<String> = plan
            .residual
            .iter()
            .filter_map(|c| match &c.term {
                Term::Text { text } if !c.negated => Some(text.clone()),
                _ => None,
            })
            .collect();
        let mut rows = plan.rows;
        let and = |rows: &mut Option<RoaringBitmap>, negated: bool, tracks: Vec<TrackId>| {
            let ids: HashSet<TrackId> = tracks.into_iter().collect();
            let mut set = RoaringBitmap::from_sorted_iter((0u32..).zip(&cols.track).filter(|(_, t)| ids.contains(t)).map(|(i, _)| i))
                .expect("indices are sorted");
            if negated {
                let mut all = cols.all();
                all -= &set;
                set = all;
            }
            *rows = Some(match rows.take() {
                Some(acc) => acc & set,
                None => set,
            });
        };
        if !words.is_empty() {
            and(&mut rows, false, self.tracks_with_text(&words)?);
        }
        for clause in &plan.residual {
            // Once nothing is left, the rest can't add anything back.
            if rows.as_ref().is_some_and(RoaringBitmap::is_empty) {
                break;
            }
            let tracks = match &clause.term {
                Term::Text { .. } if !clause.negated => continue,
                Term::Text { text } => self.tracks_with_text(std::slice::from_ref(text))?,
                Term::Person { role, name } => self.tracks_by_person(name, *role)?,
                Term::Named { field: NameField::Release, value } => self.tracks_on_release_named(value)?,
                _ => vec![],
            };
            and(&mut rows, clause.negated, tracks);
        }
        Ok(rows)
    }
}

/// See `Store::library_facts`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LibraryFacts {
    /// Releases with a present track, indexed by `Idiom as u8`; 0 is unknown.
    pub releases_by_idiom: [u64; 8],
    /// Newest first, by when their latest file joined the library.
    pub added_lately: Vec<RecentRelease>,
    /// Files whose tags couldn't be read; retried on every scan.
    pub unreadable: u64,
    /// Files that were here and have gone.
    pub missing: u64,
    /// Tracks with no artist tag.
    pub no_artist: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecentRelease {
    pub release: ReleaseId,
    pub title: String,
    pub artist: Option<String>,
    pub year: Option<u16>,
    pub tracks: u32,
    /// Unix milliseconds.
    pub added_ms: i64,
}

fn read_rows(c: &Connection, ids: &[TrackId], out: &mut HashMap<TrackId, TrackRow>) -> rusqlite::Result<()> {
    let marks = vec!["?"; ids.len()].join(",");
    let sql = format!(
        "SELECT t.id, r.id, rl.id, rl.idiom, COALESCE(t.title, r.title),
                (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 2 AND c.subject_id = r.id AND c.role = 'artist' ORDER BY c.sort LIMIT 1),
                rl.title,
                (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1),
                m.position, t.position, rl.year, COALESCE(t.length_ms, r.length_ms),
                s.codec, s.sample_rate, s.bits, ro.path, f.rel_path
         FROM track t
         JOIN recording r ON r.id = t.recording_id
         JOIN medium m ON m.id = t.medium_id
         JOIN edition e ON e.id = m.edition_id
         JOIN release rl ON rl.id = e.release_id
         LEFT JOIN source s ON s.id = {PREFERRED_SOURCE}
         LEFT JOIN file f ON f.id = s.file_id
         LEFT JOIN root ro ON ro.id = f.root_id
         WHERE t.id IN ({marks})"
    );
    let mut stmt = c.prepare_cached(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(ids.iter().map(|t| t.0)), |r| {
        let idiom: Option<u8> = r.get(3)?;
        let root: Option<String> = r.get(15)?;
        let rel: Option<String> = r.get(16)?;
        Ok(TrackRow {
            track: TrackId(r.get(0)?),
            recording: RecordingId(r.get(1)?),
            release: ReleaseId(r.get(2)?),
            idiom: idiom.and_then(|v| Idiom::ALL.into_iter().find(|i| *i as u8 == v)),
            title: r.get(4)?,
            artist: r.get(5)?,
            album: r.get(6)?,
            album_artist: r.get(7)?,
            disc: r.get(8)?,
            number: r.get(9)?,
            year: r.get(10)?,
            length_ms: r.get::<_, Option<i64>>(11)?.map(|ms| ms as u64),
            codec: r.get(12)?,
            sample_rate: r.get(13)?,
            bits: r.get(14)?,
            path: root.zip(rel).map(|(root, rel)| format!("{}/{rel}", root.trim_end_matches('/'))),
        })
    })?;
    for row in rows {
        let row = row?;
        out.insert(row.track, row);
    }
    Ok(())
}
