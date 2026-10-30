//! Reads over the library: the hot columns at start-up and after a scan,
//! and full rows for the few tracks a table page or a queue needs.

use std::collections::{HashMap, HashSet};

use meret_model::{AgentId, Idiom, RecordingId, ReleaseId, RootId, TrackId};
use meret_query::{NameField, Term};
use roaring::RoaringBitmap;
use rusqlite::{Connection, OptionalExtension};

use crate::columns::{HotColumns, Row};
use crate::plan::{Plan, format_code};
use crate::listens::COUNTED;
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
    pub artist_id: Option<AgentId>,
    pub album: String,
    pub album_artist: Option<String>,
    pub album_artist_id: Option<AgentId>,
    pub disc: u32,
    pub number: u32,
    pub year: Option<u16>,
    pub length_ms: Option<u64>,
    pub dr: Option<u8>,
    /// Integrated loudness in LUFS.
    pub loudness: Option<f64>,
    /// "FLAC", "ALAC", "AAC", "MP3"…
    pub codec: Option<String>,
    pub sample_rate: Option<u32>,
    pub bits: Option<u8>,
    /// Other known copies' codec labels, best codec excluded.
    pub other_formats: Vec<String>,
    /// The file to play, if one is present.
    pub path: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ReleaseHead {
    pub release: ReleaseId,
    pub title: String,
    pub year: Option<u16>,
    pub idiom: Option<Idiom>,
    pub album_artist: Option<(AgentId, String)>,
}

/// The album artist a release is sorted under.
const ALBUM_ARTIST: &str = "COALESCE(rl.album_artist_credit, (SELECT COALESCE(a.sort_name, a.name) FROM credit c JOIN agent a ON a.id = c.agent_id
    WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1))";

/// Shared within-release order for browsing and playback. Unknown positions
/// follow numbered ones; titles and persistent ids provide a stable fallback
/// independent of the selected file copy.
pub(crate) const TRACK_ORDER: &str = "m.position = 0, m.position, t.position = 0, t.position,
    COALESCE(t.title, r.title, '') COLLATE NOCASE, t.id";

// A bitrate wins when known; unknown legacy copies fall back to codec order.
// Lossless depth/rate never influence the lossy comparison.
macro_rules! source_quality {
    () => {
        "s2.lossless DESC,
         CASE WHEN s2.lossless THEN COALESCE(s2.bits, 0) ELSE 0 END DESC,
         CASE WHEN s2.lossless THEN COALESCE(s2.sample_rate, 0) ELSE 0 END DESC,
         CASE WHEN NOT s2.lossless THEN COALESCE(s2.bitrate_kbps, 0) ELSE 0 END DESC,
         CASE lower(s2.codec) WHEN 'opus' THEN 4 WHEN 'aac' THEN 3 WHEN 'vorbis' THEN 2 WHEN 'mp3' THEN 1 ELSE 0 END DESC,
         s2.id LIMIT 1)"
    };
}

/// The best playable file. An offline root is never sent to the decoder.
pub(crate) const PREFERRED_SOURCE: &str = concat!(
    "(SELECT s2.id FROM source s2 JOIN file f2 ON f2.id = s2.file_id JOIN root r2 ON r2.id = f2.root_id
      WHERE s2.track_id = t.id AND s2.kind = 'file' AND f2.state = 'present' AND r2.state = 'online'
      ORDER BY ", source_quality!()
);

/// The same quality ranking across every file source of a recording.
pub(crate) const PREFERRED_RECORDING_SOURCE: &str = concat!(
    "(SELECT s2.id FROM source s2 JOIN file f2 ON f2.id = s2.file_id JOIN root r2 ON r2.id = f2.root_id
      WHERE s2.recording_id = ?1 AND s2.kind = 'file' AND f2.state = 'present' AND r2.state = 'online'
      ORDER BY ", source_quality!()
);

/// Keep offline roots in the library, but prefer any online copy first.
const VISIBLE_SOURCE: &str = concat!(
    "(SELECT s2.id FROM source s2 JOIN file f2 ON f2.id = s2.file_id JOIN root r2 ON r2.id = f2.root_id
      WHERE s2.track_id = t.id AND s2.kind = 'file' AND f2.state = 'present' AND r2.state <> 'removed'
      ORDER BY (r2.state = 'online') DESC, ", source_quality!()
);

impl Store {
    /// Builds the hot columns from SQLite: one row per track with a present
    /// file, in library order (album artist, unknown last; album; disc;
    /// track; title and id for unknown/tied positions), so a result's row
    /// numbers are already sorted.
    pub fn load_columns(&self) -> Result<HotColumns> {
        self.read(|c| {
            let sql = format!(
                "SELECT t.id, COALESCE(rl.year, 0), COALESCE(t.length_ms, r.length_ms, 0),
                        COALESCE(l.plays, 0), COALESCE(l.last, 0), COALESCE(f.added_at, 0),
                        COALESCE(an.dr, e.dr, 0), COALESCE(rl.idiom, 0),
                        s.codec, s.sample_rate, s.bits, s.lossless, {ALBUM_ARTIST} AS album_artist,
                        rl.id, COALESCE(a.id, 0), COALESCE(aa.id, 0),
                        COALESCE(t.title, r.title), COALESCE(r.artist_credit, a.sort_name, a.name, rl.album_artist_credit, aa.sort_name, aa.name, ''), rl.title,
                        ro.state, an.loudness_lufs
                 FROM track t
                 JOIN recording r ON r.id = t.recording_id
                 JOIN medium m ON m.id = t.medium_id
                 JOIN edition e ON e.id = m.edition_id
                 JOIN release rl ON rl.id = e.release_id
                 JOIN source s ON s.id = {VISIBLE_SOURCE}
                 JOIN file f ON f.id = s.file_id
                 JOIN root ro ON ro.id = f.root_id
                 LEFT JOIN analysis an ON an.recording_id = r.id AND an.version = {version}
                 LEFT JOIN agent a ON a.id = (SELECT c.agent_id FROM credit c
                     WHERE c.subject_kind = 2 AND c.subject_id = r.id AND c.role = 'artist' ORDER BY c.sort LIMIT 1)
                 LEFT JOIN agent aa ON aa.id = (SELECT c.agent_id FROM credit c
                     WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1)
                 LEFT JOIN (SELECT t.id AS track_id, COUNT(*) AS plays, MAX(l.started_at) AS last
                            FROM listen l JOIN recording r ON r.id = l.recording_id
                            JOIN track t ON t.recording_id = r.id
                            WHERE {COUNTED} GROUP BY t.id) l ON l.track_id = t.id
                 ORDER BY album_artist IS NULL, album_artist COLLATE NOCASE, rl.title COLLATE NOCASE, rl.id,
                          {TRACK_ORDER}",
                version = crate::ANALYSIS_VERSION,
            );
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map([], |r| {
                let codec: Option<String> = r.get(8)?;
                let rate: Option<u32> = r.get(9)?;
                let bits: Option<u8> = r.get(10)?;
                let lossless: bool = r.get(11)?;
                Ok((Row {
                    track: r.get(0)?,
                    release: r.get(13)?,
                    artist: r.get(14)?,
                    album_artist: r.get(15)?,
                    year: r.get(1)?,
                    length_s: (r.get::<_, i64>(2)? / 1000) as u32,
                    length_ms: r.get::<_, i64>(2)?.clamp(0, u32::MAX as i64) as u32,
                    plays: r.get(3)?,
                    last_played: r.get::<_, i64>(4)? / 1000,
                    added: r.get::<_, i64>(5)? / 1000,
                    dr: r.get(6)?,
                    loudness: r.get(20)?,
                    idiom: r.get(7)?,
                    format: format_code::classify(codec.as_deref(), rate, bits, lossless),
                    availability: if r.get::<_, String>(19)? != "online" { 3 } else if lossless { 0 } else { 1 },
                    guessed: false,
                    ..Row::default()
                }, [r.get::<_, String>(16)?.to_lowercase(), r.get::<_, String>(17)?.to_lowercase(), r.get::<_, String>(18)?.to_lowercase()]))
            })?;
            let mut rows = rows.collect::<rusqlite::Result<Vec<_>>>()?;
            let mut formats = HashMap::<i64, u8>::new();
            for row in c.prepare(
                "SELECT s.track_id, s.codec, s.sample_rate, s.bits, s.lossless FROM source s
                 JOIN file f ON f.id = s.file_id JOIN root ro ON ro.id = f.root_id
                 WHERE s.kind = 'file' AND ro.state <> 'removed'"
            )?.query_map([], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, Option<u32>>(2)?,
                    r.get::<_, Option<u8>>(3)?, r.get::<_, bool>(4)?))
            })? {
                let (track, codec, rate, bits, lossless) = row?;
                let mask = formats.entry(track).or_default();
                *mask |= 1 << format_code::classify(codec.as_deref(), rate, bits, lossless);
                if codec.as_deref().is_some_and(|c| c.eq_ignore_ascii_case("MP3")) {
                    *mask |= 1 << format_code::MP3;
                }
            }
            for (row, _) in &mut rows {
                row.formats = formats.get(&row.track).copied().unwrap_or(0);
            }
            let indices: HashMap<i64, usize> = rows.iter().enumerate().map(|(i, (row, _))| (row.track, i)).collect();
            let mut people = c.prepare(
                "SELECT t.id, c.agent_id FROM track t JOIN credit c ON c.subject_kind = 2 AND c.subject_id = t.recording_id AND c.role = 'artist'
                 UNION SELECT t.id, c.agent_id FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 JOIN credit c ON c.subject_kind = 3 AND c.subject_id = e.release_id AND c.role = 'album_artist'"
            )?;
            let mut memberships = Vec::new();
            for person in people.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, u32>(1)?)))? {
                let (track, person) = person?;
                if let Some(&i) = indices.get(&track) {
                    memberships.push((i, person));
                }
            }
            for column in 0..3 {
                let mut order: Vec<usize> = (0..rows.len()).collect();
                order.sort_unstable_by(|&a, &b| natural(&rows[a].1[column], &rows[b].1[column]));
                let mut rank = 0;
                let mut previous = None;
                for i in order {
                    if previous.is_some_and(|p: usize| natural(&rows[p].1[column], &rows[i].1[column]).is_ne()) {
                        rank += 1;
                    }
                    match column {
                        0 => rows[i].0.title_rank = rank,
                        1 => rows[i].0.artist_rank = rank,
                        _ => rows[i].0.album_rank = rank,
                    }
                    previous = Some(i);
                }
            }
            let mut columns = HotColumns::from_rows(rows.into_iter().map(|(row, _)| row));
            columns.set_people(memberships);
            Ok(columns)
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

    /// Release labels for a page or a facet column, without reading its tracks.
    pub fn release_heads(&self, releases: &[ReleaseId]) -> Result<HashMap<ReleaseId, ReleaseHead>> {
        self.read(|c| {
            let mut found = HashMap::with_capacity(releases.len());
            for chunk in releases.chunks(500) {
                let marks = vec!["?"; chunk.len()].join(",");
                let sql = format!(
                    "SELECT rl.id, rl.title, rl.year, rl.idiom, a.id, COALESCE(rl.album_artist_credit, a.name) FROM release rl
                     LEFT JOIN agent a ON a.id = (SELECT c.agent_id FROM credit c
                         WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1)
                     WHERE rl.id IN ({marks})"
                );
                for row in c.prepare(&sql)?.query_map(rusqlite::params_from_iter(chunk.iter().map(|r| r.0)), |r| {
                    let idiom: Option<u8> = r.get(3)?;
                    Ok(ReleaseHead {
                        release: ReleaseId(r.get(0)?),
                        title: r.get(1)?,
                        year: r.get(2)?,
                        idiom: idiom.and_then(|v| Idiom::ALL.into_iter().find(|i| *i as u8 == v)),
                        album_artist: r.get::<_, Option<i64>>(4)?.map(|id| Ok::<_, rusqlite::Error>((AgentId(id), r.get(5)?))).transpose()?,
                    })
                })? {
                    let head = row?;
                    found.insert(head.release, head);
                }
            }
            Ok(found)
        })
    }

    pub fn agent_names(&self, agents: &[AgentId]) -> Result<HashMap<AgentId, String>> {
        self.read(|c| {
            let mut found = HashMap::with_capacity(agents.len());
            for chunk in agents.chunks(500) {
                let marks = vec!["?"; chunk.len()].join(",");
                for row in c.prepare(&format!("SELECT id, name FROM agent WHERE id IN ({marks})"))?
                    .query_map(rusqlite::params_from_iter(chunk.iter().map(|a| a.0)), |r| Ok((AgentId(r.get(0)?), r.get(1)?)))?
                {
                    let (id, name) = row?;
                    found.insert(id, name);
                }
            }
            Ok(found)
        })
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
                 WHERE {VISIBLE_SOURCE} IS NOT NULL GROUP BY 1"
            );
            for row in c.prepare(&sql)?.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)))? {
                let (idiom, n) = row?;
                if let Some(slot) = facts.releases_by_idiom.get_mut(idiom as usize) {
                    *slot = n as u64;
                }
            }

            let sql = format!(
                "SELECT rl.id, rl.title,
                        COALESCE(rl.album_artist_credit, (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                         WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1)),
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

            for row in c.prepare("SELECT f.state, COUNT(*) FROM file f JOIN root r ON r.id = f.root_id
                                 WHERE r.state <> 'removed' GROUP BY f.state")?.query_map([], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))
            })? {
                match row? {
                    (s, n) if s == "unreadable" => facts.unreadable = n,
                    _ => {}
                }
            }
            let missing_sql = format!(
                "SELECT COUNT(*) FROM track t WHERE {PREFERRED_SOURCE} IS NULL
                 AND EXISTS (SELECT 1 FROM source s JOIN file f ON f.id = s.file_id JOIN root ro ON ro.id = f.root_id
                             WHERE s.track_id = t.id AND s.kind = 'file' AND f.state = 'missing' AND ro.state <> 'removed')"
            );
            facts.missing = c.query_row(&missing_sql, [], |r| r.get::<_, i64>(0))? as u64;

            let sql = format!(
                "SELECT COUNT(*) FROM track t WHERE {PREFERRED_SOURCE} IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM credit c WHERE c.subject_kind = 2 AND c.subject_id = t.recording_id AND c.role = 'artist')"
            );
            facts.no_artist = c.query_row(&sql, [], |r| r.get::<_, i64>(0))? as u64;

            // Per folder: present files against the tracks they carry, so a
            // folder of copies says how many it set aside, and what has gone.
            let sql = "SELECT r.id,
                    (SELECT COUNT(DISTINCT f.id) FROM file f JOIN source s ON s.file_id = f.id AND s.kind = 'file'
                     WHERE f.root_id = r.id AND f.state = 'present'),
                    (SELECT COUNT(DISTINCT s.track_id) FROM file f JOIN source s ON s.file_id = f.id AND s.kind = 'file'
                     WHERE f.root_id = r.id AND f.state = 'present'),
                    (SELECT COUNT(DISTINCT f.id) FROM file f JOIN source s ON s.file_id = f.id AND s.kind = 'file'
                     WHERE f.root_id = r.id AND f.state = 'missing')
                 FROM root r WHERE r.state <> 'removed' ORDER BY r.id";
            facts.roots = c.prepare(sql)?.query_map([], |r| {
                let (files, tracks) = (r.get::<_, i64>(1)? as u64, r.get::<_, i64>(2)? as u64);
                Ok(RootFacts { root: RootId(r.get(0)?), duplicates: files.saturating_sub(tracks), missing: r.get::<_, i64>(3)? as u64 })
            })?.collect::<rusqlite::Result<_>>()?;
            Ok(facts)
        })
    }

    /// The tracks `library_facts` counts as missing, one per track with the
    /// first of its files that has gone, by folder and path.
    pub fn missing_tracks(&self) -> Result<Vec<MissingTrack>> {
        self.read(|c| {
            let sql = format!(
                "SELECT t.id, rl.id, COALESCE(t.title, r.title, ''),
                        COALESCE(r.artist_credit, (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                         WHERE c.subject_kind = 2 AND c.subject_id = r.id AND c.role = 'artist' ORDER BY c.sort LIMIT 1),
                         rl.album_artist_credit),
                        rl.title, f.rel_path, ro.label
                 FROM track t
                 JOIN recording r ON r.id = t.recording_id
                 JOIN medium m ON m.id = t.medium_id
                 JOIN edition e ON e.id = m.edition_id
                 JOIN release rl ON rl.id = e.release_id
                 JOIN file f ON f.id = (SELECT f3.id FROM source s3 JOIN file f3 ON f3.id = s3.file_id
                                        JOIN root r3 ON r3.id = f3.root_id
                                        WHERE s3.track_id = t.id AND s3.kind = 'file' AND f3.state = 'missing'
                                          AND r3.state <> 'removed' ORDER BY f3.id LIMIT 1)
                 JOIN root ro ON ro.id = f.root_id
                 WHERE {PREFERRED_SOURCE} IS NULL
                 ORDER BY ro.path, f.rel_path"
            );
            c.prepare(&sql)?.query_map([], |r| Ok(MissingTrack {
                track: TrackId(r.get(0)?), release: ReleaseId(r.get(1)?), title: r.get(2)?, artist: r.get(3)?,
                album: r.get(4)?, file: r.get(5)?, folder: r.get(6)?,
            }))?.collect()
        })
    }

    /// Why a recording has no copy to play; None when a copy is ready or no
    /// file of it is known.
    pub fn unplayable(&self, recording: RecordingId) -> Result<Option<Unplayable>> {
        self.read(|c| {
            let ready: bool = c.query_row(
                "SELECT EXISTS (SELECT 1 FROM source s JOIN file f ON f.id = s.file_id JOIN root r ON r.id = f.root_id
                 WHERE s.recording_id = ?1 AND s.kind = 'file' AND f.state = 'present' AND r.state = 'online')",
                [recording.0], |r| r.get(0))?;
            if ready {
                return Ok(None);
            }
            let worst = c.query_row(
                "SELECT f.state, f.rel_path, r.label FROM source s JOIN file f ON f.id = s.file_id JOIN root r ON r.id = f.root_id
                 WHERE s.recording_id = ?1 AND s.kind = 'file' AND r.state <> 'removed' AND f.state IN ('missing', 'present')
                 ORDER BY (f.state = 'missing') DESC, f.id LIMIT 1",
                [recording.0], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))).optional()?;
            Ok(worst.map(|(state, path, folder)| if state == "missing" {
                Unplayable::Missing { file: path.rsplit('/').next().unwrap_or(&path).to_owned() }
            } else {
                Unplayable::Offline { folder }
            }))
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
                Term::Named { field: NameField::Work, value } => self.tracks_in_work_named(value)?,
                Term::Named { field: NameField::Game, value } => self.tracks_in_game_named(value)?,
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
    /// Releases with a track in an online or offline folder, as the table
    /// counts its tracks, indexed by `Idiom as u8`; 0 is unknown.
    pub releases_by_idiom: [u64; 8],
    /// Newest first, by when their latest file joined the library.
    pub added_lately: Vec<RecentRelease>,
    /// Files whose tags couldn't be read; retried on every scan.
    pub unreadable: u64,
    /// Tracks whose files were here and have gone.
    pub missing: u64,
    /// Tracks with no artist tag.
    pub no_artist: u64,
    /// What each folder holds beyond its tracks, by root id.
    pub roots: Vec<RootFacts>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RootFacts {
    pub root: RootId,
    /// Present files that are another copy of a track the folder already
    /// holds: they stay out of the table as rows of their own.
    pub duplicates: u64,
    /// Files that were in the folder and have gone.
    pub missing: u64,
}

/// A track whose file has gone, with the file to look for.
#[derive(Clone, Debug, PartialEq)]
pub struct MissingTrack {
    pub track: TrackId,
    pub release: ReleaseId,
    pub title: String,
    pub artist: Option<String>,
    pub album: String,
    /// The file's path inside its folder.
    pub file: String,
    /// The folder's label.
    pub folder: String,
}

/// Why a recording can't be played: the file that has gone, or the folder
/// that isn't mounted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Unplayable {
    Missing { file: String },
    Offline { folder: String },
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
                COALESCE(r.artist_credit, a.name), rl.title, COALESCE(rl.album_artist_credit, aa.name),
                m.position, t.position, rl.year, COALESCE(t.length_ms, r.length_ms),
                s.codec, s.sample_rate, s.bits, ro.path, f.rel_path, a.id, aa.id,
                COALESCE(an.dr, e.dr), an.loudness_lufs
         FROM track t
         JOIN recording r ON r.id = t.recording_id
         JOIN medium m ON m.id = t.medium_id
         JOIN edition e ON e.id = m.edition_id
         JOIN release rl ON rl.id = e.release_id
         LEFT JOIN analysis an ON an.recording_id = r.id AND an.version = {version}
         LEFT JOIN agent a ON a.id = (SELECT c.agent_id FROM credit c
             WHERE c.subject_kind = 2 AND c.subject_id = r.id AND c.role = 'artist' ORDER BY c.sort LIMIT 1)
         LEFT JOIN agent aa ON aa.id = (SELECT c.agent_id FROM credit c
             WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1)
         LEFT JOIN source s ON s.id = {PREFERRED_SOURCE}
         LEFT JOIN file f ON f.id = s.file_id
         LEFT JOIN root ro ON ro.id = f.root_id
         WHERE t.id IN ({marks})",
        version = crate::ANALYSIS_VERSION,
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
            artist_id: r.get::<_, Option<i64>>(17)?.map(AgentId),
            album: r.get(6)?,
            album_artist: r.get(7)?,
            album_artist_id: r.get::<_, Option<i64>>(18)?.map(AgentId),
            disc: r.get(8)?,
            number: r.get(9)?,
            year: r.get(10)?,
            length_ms: r.get::<_, Option<i64>>(11)?.map(|ms| ms as u64),
            dr: r.get(19)?,
            loudness: r.get(20)?,
            codec: r.get(12)?,
            sample_rate: r.get(13)?,
            bits: r.get(14)?,
            other_formats: vec![],
            path: root.zip(rel).map(|(root, rel)| format!("{}/{rel}", root.trim_end_matches('/'))),
        })
    })?;
    for row in rows {
        let row = row?;
        out.insert(row.track, row);
    }
    let sql = format!(
        "SELECT DISTINCT s.track_id, s.codec FROM source s JOIN file f ON f.id = s.file_id
         JOIN root ro ON ro.id = f.root_id WHERE s.track_id IN ({marks})
         AND s.kind = 'file' AND ro.state <> 'removed' AND s.codec IS NOT NULL
         ORDER BY s.track_id, s.codec"
    );
    for row in c.prepare(&sql)?.query_map(rusqlite::params_from_iter(ids.iter().map(|t| t.0)), |r| {
        Ok((TrackId(r.get(0)?), r.get::<_, String>(1)?))
    })? {
        let (track, codec) = row?;
        if let Some(row) = out.get_mut(&track)
            && row.codec.as_deref() != Some(&codec)
        {
            row.other_formats.push(codec);
        }
    }
    Ok(())
}

/// Compares names as people read them: runs of digits by their value, so
/// "2 - Kyros" comes before "10 - Oldwalls". Both sides are lowercase.
fn natural(a: &str, b: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let digits = |s: &[u8]| s.iter().take_while(|c| c.is_ascii_digit()).count();
    // A run's value, without leading zeros (one zero stays for "0").
    fn value(s: &[u8]) -> &[u8] {
        &s[s.iter().take_while(|&&c| c == b'0').count().min(s.len().saturating_sub(1))..]
    }
    let (mut a, mut b) = (a.as_bytes(), b.as_bytes());
    loop {
        match (a.first(), b.first()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let (n, m) = (digits(a), digits(b));
                let (x, y) = (value(&a[..n]), value(&b[..m]));
                let by_value = x.len().cmp(&y.len()).then_with(|| x.cmp(y));
                if by_value.is_ne() {
                    return by_value;
                }
                (a, b) = (&a[n..], &b[m..]);
            }
            (Some(x), Some(y)) if x != y => return x.cmp(y),
            _ => (a, b) = (&a[1..], &b[1..]),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::natural;

    #[test]
    fn numbers_in_names_sort_by_value() {
        let mut names = ["10 - oldwalls", "2 - kyros", "1066 year of viking destiny", "track 02", "track 1", "b", "a10", "a9"];
        names.sort_by(|a, b| natural(a, b));
        assert_eq!(names, ["2 - kyros", "10 - oldwalls", "1066 year of viking destiny", "a9", "a10", "b", "track 1", "track 02"]);
        assert!(natural("disc 007", "disc 7").is_eq());
    }

    #[test]
    fn best_copy_quality_availability_and_any_copy_format_matching() {
        let dir = std::env::temp_dir().join(format!("meret-copies-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = crate::Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO release(id,title,rev) VALUES(1,'R',1);
                 INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
                 INSERT INTO medium(id,edition_id,position) VALUES(1,1,1);
                 INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'T',10000,1);
                 INSERT INTO track(id,medium_id,position,recording_id,title,rev) VALUES(1,1,1,1,'T',1);
                 INSERT INTO root(id,label,path,kind) VALUES(1,'Music','/music','local');"
            )?;
            for (id, codec, lossless, bits, rate, bitrate) in [
                (1, "MP3", false, None, 44100, None),
                (2, "Vorbis", false, None, 44100, None),
                (3, "AAC", false, None, 44100, None),
                (4, "Opus", false, None, 48000, None),
                (5, "MP3", false, None, 44100, Some(320)),
                (6, "FLAC", true, Some(16), 96000, None),
                (7, "FLAC", true, Some(24), 44100, None),
                (8, "FLAC", true, Some(24), 96000, None),
                (9, "MP3", false, None, 44100, Some(192)),
                (10, "FLAC", true, Some(24), 96000, None),
            ] {
                tx.execute("INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES(?1,1,?2,1,1,1)",
                    rusqlite::params![id, format!("{id}")])?;
                tx.execute("INSERT INTO source(id,recording_id,track_id,kind,file_id,codec,lossless,bits,sample_rate,bitrate_kbps,rev)
                    VALUES(?1,1,1,'file',?1,?2,?3,?4,?5,?6,1)",
                    rusqlite::params![id, codec, lossless, bits, rate, bitrate])?;
            }
            Ok(())
        }).unwrap();
        let cols = store.load_columns().unwrap();
        assert_eq!(cols.len(), 1);
        assert_eq!(cols.format, [crate::format_code::HI_RES]);
        for query in ["format:flac", "format:hires", "format:lossy", "format:mp3"] {
            let meret_query::Input::Search(q) = meret_query::parse(query).unwrap() else { unreachable!() };
            assert_eq!(crate::plan(&q, &cols, 0).rows.unwrap().len(), 1, "{query}");
        }
        assert_eq!(store.track_rows(&[meret_model::TrackId(1)]).unwrap()[0].path.as_deref(), Some("/music/8"),
            "equal-quality copies choose the lowest source id");
        assert_eq!(store.analysis_file(meret_model::RecordingId(1)).unwrap(),
            Some(std::path::PathBuf::from("/music/8")));
        store.writer.write(|tx| tx.execute("UPDATE file SET state='missing' WHERE id=10", [])).unwrap();
        for best in (1..=8).rev() {
            let rows = store.track_rows(&[meret_model::TrackId(1)]).unwrap();
            assert_eq!(rows[0].path.as_deref(), Some(format!("/music/{best}").as_str()));
            assert_eq!(store.analysis_file(meret_model::RecordingId(1)).unwrap(),
                Some(std::path::PathBuf::from(format!("/music/{best}"))));
            assert_eq!(store.load_columns().unwrap().len(), 1, "copies never multiply rows");
            assert_eq!(store.library_facts(1).unwrap().missing, 0, "one present copy is enough");
            if best == 5 {
                store.writer.write(|tx| tx.execute("UPDATE file SET state='missing' WHERE id=9", [])).unwrap();
            }
            store.writer.write(move |tx| tx.execute("UPDATE file SET state='missing' WHERE id=?1", [best])).unwrap();
        }
        assert!(store.track_rows(&[meret_model::TrackId(1)]).unwrap()[0].path.is_none());
        assert!(store.load_columns().unwrap().is_empty());
        assert_eq!(store.library_facts(1).unwrap().missing, 1, "missing counts tracks, not files");
        store.writer.write(|tx| tx.execute_batch("UPDATE file SET state='present'; UPDATE root SET state='offline';")).unwrap();
        assert!(store.track_rows(&[meret_model::TrackId(1)]).unwrap()[0].path.is_none(), "offline sources never reach playback");
        assert_eq!(store.load_columns().unwrap().availability, [3], "offline roots remain in the library");
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn missing_tracks_match_the_count_and_roots_report_duplicates_and_losses() {
        use meret_model::{RecordingId, ReleaseId, RootId, TrackId};
        let dir = std::env::temp_dir().join(format!("meret-missing-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = crate::Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| tx.execute_batch("
            INSERT INTO release(id,title,rev) VALUES(1,'Suite',1);
            INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
            INSERT INTO medium(id,edition_id,position) VALUES(1,1,1);
            INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'Copied',1000,1),(2,'Gone',1000,1),(3,'Back',1000,1),(4,'Away',1000,1),(5,'Unknown',1000,1);
            INSERT INTO track(id,medium_id,position,recording_id,title,rev) VALUES(1,1,1,1,'Copied',1),(2,1,2,2,'Gone',1),(3,1,3,3,'Back',1),(4,1,4,4,'Away',1),(5,1,5,5,'Unknown',1);
            INSERT INTO root(id,label,path,kind,state) VALUES(1,'Music','/music','local','online'),(2,'Archive','/archive','local','offline');
            INSERT INTO file(id,root_id,rel_path,size,mtime_ns,state,added_at,rev) VALUES
                (1,1,'one.flac',1,1,'present',1,1),(2,1,'copy/one.flac',1,1,'present',1,1),
                (3,1,'disc/two.flac',1,1,'missing',1,1),
                (4,1,'three.flac',1,1,'present',1,1),(5,1,'three-old.flac',1,1,'missing',1,1),
                (6,2,'four.flac',1,1,'present',1,1);
            INSERT INTO source(id,recording_id,track_id,kind,file_id,lossless,rev) VALUES
                (1,1,1,'file',1,1,1),(2,1,1,'file',2,1,1),(3,2,2,'file',3,1,1),
                (4,3,3,'file',4,1,1),(5,3,3,'file',5,1,1),(6,4,4,'file',6,1,1);
        ")).unwrap();

        let facts = store.library_facts(3).unwrap();
        let missing = store.missing_tracks().unwrap();
        assert_eq!(facts.missing, missing.len() as u64, "the sidebar count is the table's length");
        assert_eq!(missing, [super::MissingTrack {
            track: TrackId(2), release: ReleaseId(1), title: "Gone".into(), artist: None, album: "Suite".into(),
            file: "disc/two.flac".into(), folder: "Music".into(),
        }]);
        assert_eq!(facts.releases_by_idiom.iter().sum::<u64>(), 1, "a release counts once, offline tracks included");
        let by_root = |root| facts.roots.iter().find(|r| r.root == RootId(root)).unwrap();
        assert_eq!((by_root(1).duplicates, by_root(1).missing), (1, 2), "one extra copy of Copied; Gone and Back's old file are gone");
        assert_eq!((by_root(2).duplicates, by_root(2).missing), (0, 0));

        let why = |recording| store.unplayable(RecordingId(recording)).unwrap();
        assert_eq!(why(2), Some(super::Unplayable::Missing { file: "two.flac".into() }));
        assert_eq!(why(4), Some(super::Unplayable::Offline { folder: "Archive".into() }));
        assert_eq!(why(1), None, "a copy is ready");
        assert_eq!(why(3), None, "a copy is ready beside the one that went");
        assert_eq!(why(5), None, "no file is known at all");
        drop(store);
        std::fs::remove_dir_all(dir).ok();
    }
}
