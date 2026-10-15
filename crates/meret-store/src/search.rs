//! Full-text search over people, releases and recordings.
//!
//! One FTS5 table with the trigram tokenizer, so CJK titles match. Rows
//! and typed words are both folded by `fold` (lowercase, no accents, ø as
//! o), so "olafsson" finds Ólafsson the same way on every path. A typed
//! word matches where a word starts ("iona" finds Iona, not "traditional"),
//! checked by `word_match` on the rows the trigram index finds. A word of
//! fewer than three characters can't use the index, so on its own it scans
//! the table.
//!
//! The scan keeps the table current through `index_*`, inside its own
//! write; migration 0003 filled it for libraries scanned before.

use std::collections::HashSet;

use meret_model::{AgentId, EntityKind, ReleaseId, TrackId};
use meret_query::Role;
use rusqlite::functions::FunctionFlags;
use rusqlite::{Connection, Transaction, params, params_from_iter};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

use crate::{Result, Store};

/// A row's rowid: one slot per entity kind, so replacing an entity's row
/// is a lookup by key.
fn rowid(kind: EntityKind, id: i64) -> i64 {
    id * 16 + kind as i64
}

const RECORDING_ROW: &str = "SELECT ?1, 2, r.id, search_fold(r.title),
       search_fold(COALESCE((SELECT group_concat(a.name, ' · ') FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 2 AND c.subject_id = r.id), '')),
       search_fold(COALESCE((SELECT group_concat(x, ' · ') FROM (
                   SELECT DISTINCT rl.title AS x FROM track t JOIN medium m ON m.id = t.medium_id
                   JOIN edition e ON e.id = m.edition_id JOIN release rl ON rl.id = e.release_id
                   WHERE t.recording_id = r.id
                   UNION
                   SELECT a.name FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                   JOIN credit c ON c.subject_kind = 3 AND c.subject_id = e.release_id JOIN agent a ON a.id = c.agent_id
                   WHERE t.recording_id = r.id)), ''))
FROM recording r WHERE r.id = ?2";

const RELEASE_ROW: &str = "SELECT ?1, 3, rl.id, search_fold(rl.title),
       search_fold(COALESCE((SELECT group_concat(a.name, ' · ') FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 3 AND c.subject_id = rl.id), '')),
       ''
FROM release rl WHERE rl.id = ?2";

const AGENT_ROW: &str =
    "SELECT ?1, 6, a.id, search_fold(a.name), '', search_fold(COALESCE(a.sort_name, '')) FROM agent a WHERE a.id = ?2";

/// Writes the search row for a recording: its title, its artists, and the
/// releases it is on with their album artists. Call after its credits.
pub fn index_recording(tx: &Transaction<'_>, id: i64) -> rusqlite::Result<()> {
    replace(tx, EntityKind::Recording, id, RECORDING_ROW)
}

/// Writes the search row for a release. Call after its album artist credit.
pub fn index_release(tx: &Transaction<'_>, id: i64) -> rusqlite::Result<()> {
    replace(tx, EntityKind::Release, id, RELEASE_ROW)
}

pub fn index_agent(tx: &Transaction<'_>, id: i64) -> rusqlite::Result<()> {
    replace(tx, EntityKind::Agent, id, AGENT_ROW)
}

fn replace(tx: &Transaction<'_>, kind: EntityKind, id: i64, select: &str) -> rusqlite::Result<()> {
    let key = rowid(kind, id);
    tx.execute("DELETE FROM search WHERE rowid = ?1", [key])?;
    tx.prepare_cached(&format!("INSERT INTO search (rowid, entity_kind, entity_id, title, people, extra) {select}"))?
        .execute(params![key, id])?;
    Ok(())
}

/// Which columns a match looks at.
#[derive(Clone, Copy)]
enum Scope {
    /// Title, people and extra.
    Row,
    Title,
}

/// A WHERE condition on `search` that holds when every word starts a word
/// in `scope`, and its parameters, numbered from `?1`, so a statement can
/// use the condition twice and bind the parameters once. `None` for no
/// words. Words of three or more characters narrow the rows through the
/// trigram index first.
fn matching(words: &[String], scope: Scope) -> Option<(String, Vec<String>)> {
    let words: Vec<String> = words.iter().map(|w| fold_str(w)).filter(|w| !w.trim().is_empty()).collect();
    if words.is_empty() {
        return None;
    }
    let columns = match scope {
        Scope::Row => "title, people, extra",
        Scope::Title => "title",
    };
    let mut sql = vec![];
    let mut params = vec![];
    let long: Vec<String> =
        words.iter().filter(|w| w.chars().count() >= 3).map(|w| format!("\"{}\"", w.replace('"', "\"\""))).collect();
    if !long.is_empty() {
        let expr = long.join(" AND ");
        params.push(match scope {
            Scope::Row => expr,
            Scope::Title => format!("title : ({expr})"),
        });
        sql.push(format!("search MATCH ?{}", params.len()));
    }
    for w in words {
        params.push(w);
        sql.push(format!("word_match(?{}, {columns})", params.len()));
    }
    Some((sql.join(" AND "), params))
}

/// Registers `word_match(word, text…)`, true when `word_match` holds for
/// any of the texts, and `search_fold(text)`, which the rows are written
/// through.
pub(crate) fn register(conn: &Connection) -> rusqlite::Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC;
    conn.create_scalar_function("word_match", -1, flags, |ctx| {
        let word = ctx.get_raw(0).as_str().unwrap_or("");
        Ok((1..ctx.len()).any(|i| ctx.get_raw(i).as_str().is_ok_and(|text| word_match(text, word))))
    })?;
    conn.create_scalar_function("search_fold", 1, flags, |ctx| Ok(ctx.get::<Option<String>>(0)?.map(|s| fold_str(&s))))
}

/// Whether `word` appears in `text` where a word starts, ignoring case and
/// accents. The trigram index finds substrings anywhere ("iona" inside
/// "traditional"); this keeps the ones a person means. Scripts written
/// without spaces (Chinese, Japanese) have no word starts, so they match
/// anywhere.
fn word_match(text: &str, word: &str) -> bool {
    // Most of a library is ASCII; this runs on every row a scan reads.
    if text.is_ascii() && word.is_ascii() {
        let (t, w) = (text.as_bytes(), word.as_bytes());
        let Some(&first) = w.first() else { return true };
        return t.len() >= w.len()
            && (0..=t.len() - w.len()).any(|i| {
                t[i..i + w.len()].eq_ignore_ascii_case(w) && (i == 0 || !(t[i - 1].is_ascii_alphanumeric() && first.is_ascii_alphanumeric()))
            });
    }
    let text = fold(text);
    let word = fold(word);
    let Some(&first) = word.first() else { return true };
    // Letters and digits of scripts that separate words with spaces.
    let spaced = |c: char| c.is_alphanumeric() && !unspaced(c);
    text.windows(word.len())
        .enumerate()
        .any(|(i, w)| w == word.as_slice() && (i == 0 || !(spaced(text[i - 1]) && spaced(first))))
}

/// Scripts written without spaces between words: Chinese, Japanese, Thai,
/// Lao, Khmer, Burmese.
fn unspaced(c: char) -> bool {
    matches!(c as u32,
        0x0E00..=0x0EFF | 0x1000..=0x109F | 0x1780..=0x17FF | 0x3040..=0x30FF | 0x3400..=0x4DBF
        | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0xFF66..=0xFF9F | 0x20000..=0x3FFFF)
}

/// What rows are written as and words are matched as.
pub(crate) fn fold_str(s: &str) -> String {
    fold(s).into_iter().collect()
}

/// Lowercase, without accents, with a few letters that don't decompose
/// (ø, ł, đ, ħ) read as their base letter.
fn fold(s: &str) -> Vec<char> {
    s.nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .map(|c| match c {
            'ø' => 'o',
            'ł' => 'l',
            'đ' => 'd',
            'ħ' => 'h',
            c => c,
        })
        .collect()
}

/// A track with a present file: what the table shows and hits count.
const PRESENT: &str = "EXISTS (SELECT 1 FROM source s JOIN file f ON f.id = s.file_id
    JOIN root r ON r.id = f.root_id
    WHERE s.track_id = {t}.id AND s.kind = 'file' AND f.state = 'present' AND r.state <> 'removed')";

/// The tracks credited to agent `{a}`: as a recording's artist, or on a
/// release they are the album artist of.
const AGENT_TRACKS: &str = "SELECT t.id FROM credit c JOIN track t ON t.recording_id = c.subject_id
        WHERE c.subject_kind = 2 AND c.agent_id = {a}
    UNION
    SELECT t.id FROM credit c JOIN edition e ON e.release_id = c.subject_id JOIN medium m ON m.edition_id = e.id
        JOIN track t ON t.medium_id = m.id WHERE c.subject_kind = 3 AND c.agent_id = {a}";

/// How many candidates hits are ranked from. A word like "the" matches far
/// more; the best of them sort first by name.
const CANDIDATES: usize = 200;

/// Someone whose name matched, with how many present tracks they're on.
#[derive(Clone, Debug, PartialEq)]
pub struct PersonHit {
    pub agent: AgentId,
    pub name: String,
    pub tracks: u32,
}

/// A release whose title matched.
#[derive(Clone, Debug, PartialEq)]
pub struct ReleaseHit {
    pub release: ReleaseId,
    pub title: String,
    pub artist: Option<String>,
    pub year: Option<u16>,
    pub tracks: u32,
}

impl Store {
    /// Tracks whose title, artist, album or album artist contain every
    /// word, ignoring case and accents.
    pub fn tracks_with_text(&self, words: &[String]) -> Result<Vec<TrackId>> {
        let Some((cond, params)) = matching(words, Scope::Row) else { return Ok(vec![]) };
        self.read(|c| {
            ids(
                c,
                &format!(
                    "SELECT t.id FROM track t WHERE t.recording_id IN
                         (SELECT entity_id FROM search WHERE {cond} AND entity_kind = 2)"
                ),
                params,
            )
        })
    }

    /// Tracks whose own title contains every word.
    pub fn tracks_titled(&self, words: &[String]) -> Result<HashSet<TrackId>> {
        let Some((cond, params)) = matching(words, Scope::Title) else { return Ok(HashSet::new()) };
        self.read(|c| {
            let sql = format!(
                "SELECT t.id FROM track t WHERE t.recording_id IN
                     (SELECT entity_id FROM search WHERE {cond} AND entity_kind = 2)"
            );
            Ok(ids(c, &sql, params)?.into_iter().collect())
        })
    }

    /// Exact names take precedence over contains matches. Any credit counts
    /// when `role` is `None`; the scan writes artists and album artists.
    pub fn tracks_by_person(&self, name: &str, role: Option<Role>) -> Result<Vec<TrackId>> {
        let Some((cond, mut params)) = matching(&[name.to_string()], Scope::Title) else { return Ok(vec![]) };
        params.push(name.to_string());
        let n = params.len();
        let agents = format!(
            "SELECT id FROM agent WHERE name = ?{n} COLLATE NOCASE
             UNION SELECT entity_id FROM search WHERE {cond} AND entity_kind = 6
             AND NOT EXISTS (SELECT 1 FROM agent WHERE name = ?{n} COLLATE NOCASE)"
        );
        let sql = match role {
            None => format!(
                "SELECT t.id FROM credit c JOIN track t ON t.recording_id = c.subject_id
                     WHERE c.subject_kind = 2 AND c.agent_id IN ({agents})
                 UNION
                 SELECT t.id FROM credit c JOIN edition e ON e.release_id = c.subject_id
                     JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
                     WHERE c.subject_kind = 3 AND c.agent_id IN ({agents})"
            ),
            Some(role) => {
                params.push(credit_role(role).to_string());
                let n = params.len();
                format!(
                    "SELECT t.id FROM credit c JOIN track t ON t.recording_id = c.subject_id
                     WHERE c.subject_kind = 2 AND c.role = ?{n} AND c.agent_id IN ({agents})"
                )
            }
        };
        self.read(|c| ids(c, &sql, params))
    }

    /// Exact release titles take precedence over contains matches.
    pub fn tracks_on_release_named(&self, title: &str) -> Result<Vec<TrackId>> {
        let Some((cond, mut params)) = matching(&[title.to_string()], Scope::Title) else { return Ok(vec![]) };
        params.push(title.to_string());
        let n = params.len();
        self.read(|c| {
            ids(
                c,
                &format!(
                    "SELECT t.id FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                     WHERE e.release_id IN (
                         SELECT id FROM release WHERE title = ?{n} COLLATE NOCASE
                         UNION SELECT entity_id FROM search WHERE {cond} AND entity_kind = 3
                         AND NOT EXISTS (SELECT 1 FROM release WHERE title = ?{n} COLLATE NOCASE))"
                ),
                params,
            )
        })
    }

    /// People whose name contains every word: how many match, and the best
    /// `limit` with a present track. Names that start with the first word
    /// rank first, then those on the most tracks.
    pub fn people_hits(&self, words: &[String], limit: usize) -> Result<(u64, Vec<PersonHit>)> {
        let Some((cond, params)) = matching(words, Scope::Title) else { return Ok((0, vec![])) };
        let prefix = starts_with(&fold_str(&words[0]));
        let present = PRESENT.replace("{t}", "u");
        let tracks = AGENT_TRACKS.replace("{a}", "a.id");
        // Only people on a present track count, before the candidates are cut.
        let eligible = format!(
            "FROM agent a WHERE a.id IN (SELECT entity_id FROM search WHERE {cond} AND entity_kind = 6)
             AND EXISTS (SELECT 1 FROM ({tracks}) u WHERE {present})"
        );
        self.read(|c| {
            let total = count(c, &format!("SELECT COUNT(*) {eligible}"), &params)?;
            let n = params.len() + 1;
            let tracks = AGENT_TRACKS.replace("{a}", "x.id");
            let sql = format!(
                "SELECT x.id, x.name, x.p, (SELECT COUNT(*) FROM ({tracks}) u WHERE {present}) FROM
                     (SELECT a.id, a.name, search_fold(a.name) LIKE ?{n} ESCAPE '\\' AS p {eligible}
                      ORDER BY p DESC, a.name COLLATE NOCASE LIMIT {CANDIDATES}) x"
            );
            let mut hits: Vec<(bool, PersonHit)> = c
                .prepare(&sql)?
                .query_map(params_from_iter(params.iter().chain([&prefix])), |r| {
                    Ok((r.get(2)?, PersonHit { agent: AgentId(r.get(0)?), name: r.get(1)?, tracks: r.get(3)? }))
                })?
                .collect::<rusqlite::Result<_>>()?;
            hits.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.tracks.cmp(&a.1.tracks)));
            Ok((total, hits.into_iter().take(limit).map(|(_, h)| h).collect()))
        })
    }

    /// Releases whose title contains every word, ranked like people.
    pub fn release_hits(&self, words: &[String], limit: usize) -> Result<(u64, Vec<ReleaseHit>)> {
        let Some((cond, params)) = matching(words, Scope::Title) else { return Ok((0, vec![])) };
        let prefix = starts_with(&fold_str(&words[0]));
        let present = PRESENT.replace("{t}", "t");
        let eligible = format!(
            "FROM release rl WHERE rl.id IN (SELECT entity_id FROM search WHERE {cond} AND entity_kind = 3)
             AND EXISTS (SELECT 1 FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
                         WHERE e.release_id = rl.id AND {present})"
        );
        self.read(|c| {
            let total = count(c, &format!("SELECT COUNT(*) {eligible}"), &params)?;
            let n = params.len() + 1;
            let sql = format!(
                "SELECT x.id, x.title, x.p, x.year,
                        (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                         WHERE c.subject_kind = 3 AND c.subject_id = x.id AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1),
                        (SELECT COUNT(*) FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
                         WHERE e.release_id = x.id AND {present})
                 FROM (SELECT rl.id, rl.title, rl.year, search_fold(rl.title) LIKE ?{n} ESCAPE '\\' AS p {eligible}
                       ORDER BY p DESC, rl.title COLLATE NOCASE LIMIT {CANDIDATES}) x"
            );
            let mut hits: Vec<(bool, ReleaseHit)> = c
                .prepare(&sql)?
                .query_map(params_from_iter(params.iter().chain([&prefix])), |r| {
                    Ok((
                        r.get(2)?,
                        ReleaseHit {
                            release: ReleaseId(r.get(0)?),
                            title: r.get(1)?,
                            year: r.get(3)?,
                            artist: r.get(4)?,
                            tracks: r.get(5)?,
                        },
                    ))
                })?
                .collect::<rusqlite::Result<_>>()?;
            hits.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.tracks.cmp(&a.1.tracks)));
            Ok((total, hits.into_iter().take(limit).map(|(_, h)| h).collect()))
        })
    }
}

/// The credit role a query role reads. The scan writes a file's artist tag
/// as `artist`, which is who performs it.
fn credit_role(role: Role) -> &'static str {
    match role {
        Role::Performer => "artist",
        other => other.as_str(),
    }
}

fn escape_like(s: &str) -> String {
    s.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

fn starts_with(word: &str) -> String {
    format!("{}%", escape_like(word))
}

fn ids(c: &Connection, sql: &str, params: Vec<String>) -> rusqlite::Result<Vec<TrackId>> {
    c.prepare(sql)?.query_map(params_from_iter(params), |r| Ok(TrackId(r.get(0)?)))?.collect()
}

fn count(c: &Connection, sql: &str, params: &[String]) -> rusqlite::Result<u64> {
    c.query_row(sql, params_from_iter(params), |r| r.get::<_, i64>(0)).map(|n| n as u64)
}

#[cfg(test)]
mod tests {
    use super::word_match;

    #[test]
    fn words_match_where_a_word_starts() {
        assert!(word_match("Iona Brown", "iona"));
        assert!(word_match("Joanne Hogg · Iona", "iona"));
        assert!(!word_match("Ramkhamhaeng War (Siam) – traditional", "iona"));
        assert!(word_match("(Iona)", "iona"), "punctuation starts a word");
        assert!(word_match("Víkingur Ólafsson", "olafsson"), "accents fold");
        assert!(word_match("Mikkel Bødtker", "bodtker"));
        assert!(word_match("Baldur's Gate", "baldur's g"), "a phrase");
        assert!(!word_match("1972", "72"));
        assert!(word_match("光田康典", "康典"), "no word starts without spaces");
        assert!(!word_match("سلام", "لام"), "Arabic separates words with spaces");
    }

    #[test]
    fn exact_person_and_release_names_win_over_contains() {
        use crate::Store;
        use meret_model::TrackId;
        use meret_query::Role;

        let dir = std::env::temp_dir().join(format!("meret-exact-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO agent (id, kind, name, rev) VALUES (1, 0, 'Mark Cromer', 1), (2, 0, 'Mark Cromer Ensemble', 1);
                 INSERT INTO release (id, title, rev) VALUES (1, 'Civilization V', 1), (2, 'Civilization V Expanded', 1);
                 INSERT INTO edition (id, release_id, rev) VALUES (1, 1, 1), (2, 2, 1);
                 INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 1), (2, 2, 1);
                 INSERT INTO recording (id, title, rev) VALUES (1, 'First', 1), (2, 'Second', 1);
                 INSERT INTO track (id, medium_id, recording_id, position, rev) VALUES (1, 1, 1, 1, 1), (2, 2, 2, 1, 1);
                 INSERT INTO credit (subject_kind, subject_id, agent_id, role, rev) VALUES (2, 1, 1, 'artist', 1), (2, 2, 2, 'artist', 1);"
            )?;
            for id in [1, 2] {
                super::index_agent(tx, id)?;
                super::index_release(tx, id)?;
            }
            Ok(())
        }).unwrap();
        assert_eq!(store.tracks_by_person("MARK CROMER", None).unwrap(), vec![TrackId(1)]);
        assert_eq!(store.tracks_by_person("Mark Cromer", Some(Role::Performer)).unwrap(), vec![TrackId(1)]);
        assert_eq!(store.tracks_by_person("cromer", None).unwrap(), vec![TrackId(1), TrackId(2)]);
        assert_eq!(store.tracks_on_release_named("CIVILIZATION V").unwrap(), vec![TrackId(1)]);
        assert_eq!(store.tracks_on_release_named("Civilization").unwrap(), vec![TrackId(1), TrackId(2)]);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
