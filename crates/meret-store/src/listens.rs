//! Listening memory. Times are Unix milliseconds; only counted listens feed
//! plays, last played, Most played and Dormant. History keeps every attempt.

use meret_model::{ListenUid, RecordingId, ReleaseId, SourceId, StopUid, TrackId};
use rusqlite::{OptionalExtension, params};

use crate::{Result, Store};

/// Shared by history, aggregates and the hot-column load. Zero/missing length
/// is unknown, not a zero-second recording that counts as soon as it opens.
pub(crate) const COUNTED: &str = "l.played_ms >= CASE WHEN COALESCE(r.length_ms, t.length_ms, 0) > 0
    THEN MIN(COALESCE(r.length_ms, t.length_ms) / 2, 240000) ELSE 240000 END";

// A source preserves which release was heard when a recording has several
// editions. Older/source-less listens get one deterministic track, not a row
// per edition. Keep recording-only listens in history even without a track.
const LISTEN_TRACK: &str = "LEFT JOIN source s ON s.id = l.source_id
    LEFT JOIN track t ON t.id = COALESCE(s.track_id,
        (SELECT MIN(t2.id) FROM track t2 WHERE t2.recording_id = l.recording_id))
    LEFT JOIN recording r ON r.id = l.recording_id
    LEFT JOIN medium m ON m.id = t.medium_id
    LEFT JOIN edition e ON e.id = m.edition_id
    LEFT JOIN release rl ON rl.id = e.release_id";
const CREDIT: &str = "COALESCE(r.artist_credit,
    (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
     WHERE c.subject_kind = 2 AND c.subject_id = r.id AND c.role = 'artist' ORDER BY c.sort, c.id LIMIT 1),
    rl.album_artist_credit,
    (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
     WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort, c.id LIMIT 1))";
const RELEASE_CREDIT: &str = "COALESCE(rl.album_artist_credit,
    (SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
     WHERE c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist' ORDER BY c.sort, c.id LIMIT 1))";
const COVER: &str = "(SELECT lower(hex(ea.hash)) FROM entity_artwork ea
    WHERE ea.entity_kind = 3 AND ea.entity_id = rl.id LIMIT 1)";
const DORMANT_MS: i64 = 180 * 86_400_000;

#[derive(Clone, Debug, PartialEq)]
pub struct ListenRow {
    pub uid: String,
    pub track: Option<TrackId>,
    pub recording: RecordingId,
    pub release: Option<ReleaseId>,
    pub title: String,
    pub credit: Option<String>,
    pub release_title: Option<String>,
    /// Cover hash; resolve it at the API boundary like the other library reads.
    pub cover: Option<String>,
    pub started_at: i64,
    pub played_ms: u64,
    pub length_ms: Option<u64>,
    pub counted: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlayCount {
    pub track: TrackId,
    pub recording: RecordingId,
    pub release: ReleaseId,
    pub title: String,
    pub credit: Option<String>,
    pub release_title: String,
    pub cover: Option<String>,
    pub plays: u64,
    pub last_played: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Dormant {
    pub release: ReleaseId,
    pub title: String,
    pub credit: Option<String>,
    pub cover: Option<String>,
    pub plays: u64,
    pub last_played: i64,
}

impl Store {
    #[allow(clippy::too_many_arguments)]
    pub fn start_listen(&self, uid: ListenUid, recording: RecordingId, source: Option<SourceId>, zone: String,
        started_at_ms: i64, from_stop: Option<StopUid>, device: String) -> Result<()> {
        self.writer.write(move |tx| {
            tx.execute("INSERT INTO listen (uid, recording_id, source_id, zone, started_at, played_ms, from_stop, device)
                VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7)",
                params![uid.to_string(), recording.0, source.map(|s| s.0), zone, started_at_ms, from_stop.map(|s| s.to_string()), device])?;
            Ok(())
        })
    }

    /// Writes how far a listen got, while it plays and when it ends, and
    /// returns whether it counts, using the same rule as reads.
    pub fn update_listen(&self, uid: ListenUid, played_ms: u64) -> Result<bool> {
        self.writer.write(move |tx| {
            let uid = uid.to_string();
            let played_ms = i64::try_from(played_ms).map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
            tx.execute("UPDATE listen SET played_ms = ?2 WHERE uid = ?1", params![uid, played_ms])?;
            tx.query_row(&format!("SELECT {COUNTED} FROM listen l {LISTEN_TRACK} WHERE l.uid = ?1"),
                [uid], |r| r.get(0))
        })
    }

    /// A listen's recording, start and whether it counts yet, for continuing it.
    pub fn listen(&self, uid: ListenUid) -> Result<Option<(RecordingId, i64, bool)>> {
        self.read(|c| c.query_row(&format!("SELECT l.recording_id, l.started_at, {COUNTED} FROM listen l {LISTEN_TRACK}
            WHERE l.uid = ?1 AND l.recording_id IS NOT NULL"), [uid.to_string()],
            |r| Ok((RecordingId(r.get(0)?), r.get(1)?, r.get(2)?))).optional())
    }

    /// The source that the player will choose for this library track.
    pub fn listen_source(&self, track: TrackId) -> Result<Option<SourceId>> {
        self.read(|c| c.query_row(&format!("SELECT {} FROM track t WHERE t.id = ?1", crate::library::PREFERRED_SOURCE),
            [track.0], |r| r.get::<_, Option<i64>>(0)).optional().map(|s| s.flatten().map(SourceId)))
    }

    pub fn history(&self, limit: u32) -> Result<Vec<ListenRow>> {
        self.read(|c| {
            let mut stmt = c.prepare(&format!("SELECT l.uid, t.id, l.recording_id, rl.id,
                COALESCE(t.title, r.title, ''), {CREDIT}, rl.title, {COVER}, l.started_at,
                l.played_ms, COALESCE(r.length_ms, t.length_ms), {COUNTED}
                FROM listen l {LISTEN_TRACK} WHERE l.recording_id IS NOT NULL
                ORDER BY l.started_at DESC, l.uid DESC LIMIT ?1"))?;
            stmt.query_map([limit], |r| Ok(ListenRow {
                uid: r.get(0)?, track: r.get::<_, Option<i64>>(1)?.map(TrackId), recording: RecordingId(r.get(2)?),
                release: r.get::<_, Option<i64>>(3)?.map(ReleaseId), title: r.get(4)?, credit: r.get(5)?,
                release_title: r.get(6)?, cover: r.get(7)?, started_at: r.get(8)?, played_ms: r.get::<_, i64>(9)? as u64,
                length_ms: r.get::<_, Option<i64>>(10)?.map(|ms| ms as u64), counted: r.get(11)?,
            }))?.collect()
        })
    }

    pub fn most_played(&self, since_ms: i64, limit: u32) -> Result<Vec<PlayCount>> {
        self.read(|c| {
            let mut stmt = c.prepare(&format!("SELECT t.id, r.id, rl.id, COALESCE(t.title, r.title),
                {CREDIT}, rl.title, {COVER}, COUNT(*), MAX(l.started_at)
                FROM listen l {LISTEN_TRACK} WHERE t.id IS NOT NULL AND l.started_at >= ?1 AND {COUNTED}
                GROUP BY t.id ORDER BY COUNT(*) DESC, MAX(l.started_at) DESC, t.id LIMIT ?2"))?;
            stmt.query_map(params![since_ms, limit], |r| Ok(PlayCount {
                track: TrackId(r.get(0)?), recording: RecordingId(r.get(1)?), release: ReleaseId(r.get(2)?),
                title: r.get(3)?, credit: r.get(4)?, release_title: r.get(5)?, cover: r.get(6)?, plays: r.get::<_, i64>(7)? as u64, last_played: r.get(8)?,
            }))?.collect()
        })
    }

    pub fn dormant(&self, limit: u32) -> Result<Vec<Dormant>> {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
        self.dormant_before(now - DORMANT_MS, limit)
    }

    pub fn dormant_before(&self, before_ms: i64, limit: u32) -> Result<Vec<Dormant>> {
        self.read(|c| {
            let mut stmt = c.prepare(&format!("SELECT rl.id, rl.title, {RELEASE_CREDIT}, {COVER}, COUNT(*), MAX(l.started_at)
                FROM listen l {LISTEN_TRACK} WHERE rl.id IS NOT NULL AND {COUNTED}
                GROUP BY rl.id HAVING COUNT(*) >= 5 AND MAX(l.started_at) < ?1
                ORDER BY MAX(l.started_at), rl.id LIMIT ?2"))?;
            stmt.query_map(params![before_ms, limit], |r| Ok(Dormant {
                release: ReleaseId(r.get(0)?), title: r.get(1)?, credit: r.get(2)?, cover: r.get(3)?, plays: r.get::<_, i64>(4)? as u64, last_played: r.get(5)?,
            }))?.collect()
        })
    }

    /// Counted plays of a release and when it was last played, for its pane's facts.
    pub fn release_plays(&self, release: ReleaseId) -> Result<(u64, Option<i64>)> {
        self.read(|c| c.query_row(&format!("SELECT COUNT(*), MAX(l.started_at) FROM listen l {LISTEN_TRACK}
            WHERE rl.id = ?1 AND {COUNTED}"), [release.0],
            |r| Ok((r.get::<_, i64>(0)? as u64, r.get(1)?))))
    }

    /// Counted plays of a person's recordings and the releases they front.
    pub fn person_plays(&self, agent: meret_model::AgentId) -> Result<(u64, Option<i64>)> {
        self.read(|c| c.query_row(&format!("SELECT COUNT(*), MAX(l.started_at) FROM listen l {LISTEN_TRACK}
            WHERE {COUNTED} AND EXISTS (SELECT 1 FROM credit c WHERE c.agent_id = ?1
                AND ((c.subject_kind = 2 AND c.subject_id = l.recording_id AND c.role = 'artist')
                  OR (c.subject_kind = 3 AND c.subject_id = rl.id AND c.role = 'album_artist')))"), [agent.0],
            |r| Ok((r.get::<_, i64>(0)? as u64, r.get(1)?))))
    }

    /// Releases with a playable track and no counted play, by id, each with
    /// when its newest file arrived. Play something rotates through them.
    pub fn never_played(&self) -> Result<Vec<(ReleaseId, Option<i64>)>> {
        self.read(|c| {
            let mut stmt = c.prepare(&format!("SELECT x.id, MAX(f.added_at)
                FROM release x
                JOIN edition e ON e.release_id = x.id JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
                JOIN source s ON s.id = {} JOIN file f ON f.id = s.file_id
                WHERE NOT EXISTS (SELECT 1 FROM listen l {LISTEN_TRACK} WHERE rl.id = x.id AND {COUNTED})
                GROUP BY x.id ORDER BY x.id", crate::library::PREFERRED_SOURCE))?;
            stmt.query_map([], |r| Ok((ReleaseId(r.get(0)?), r.get(1)?)))?.collect()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Store, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("meret-listens-{}", ListenUid::new()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| tx.execute_batch("
            INSERT INTO release (id, title, rev) VALUES (1, 'Test release', 1);
            INSERT INTO edition (id, release_id, rev) VALUES (1, 1, 1);
            INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 1);
            INSERT INTO recording (id, title, length_ms, rev) VALUES (1, 'Short', 100000, 1), (2, 'Long', 600000, 1), (3, 'Unknown', NULL, 1), (4, 'Zero', 0, 1);
            INSERT INTO track (id, medium_id, position, recording_id, rev) VALUES (1, 1, 1, 1, 1), (2, 1, 2, 2, 1), (3, 1, 3, 3, 1), (4, 1, 4, 4, 1);
            INSERT INTO root (id, label, path, kind, state) VALUES (1, 'Test root', '/test', 'local', 'online');
            INSERT INTO file (id, root_id, rel_path, size, mtime_ns, state, added_at, rev) VALUES (1, 1, 'short.flac', 1, 1, 'present', 1, 1);
            INSERT INTO source (id, recording_id, track_id, kind, file_id, lossless, rev) VALUES (1, 1, 1, 'file', 1, 1, 1);
        ")).unwrap();
        (store, dir)
    }

    fn listen(store: &Store, recording: i64, at: i64, played: u64) -> bool {
        let uid = ListenUid::new();
        store.start_listen(uid, RecordingId(recording), None, "local".into(), at, None, store.device_id().unwrap()).unwrap();
        store.update_listen(uid, played).unwrap()
    }

    #[test]
    fn counting_boundaries_history_order_and_hot_columns_agree() {
        let (store, dir) = fixture();
        assert!(!listen(&store, 1, 1_000, 49_000));
        assert!(listen(&store, 1, 2_000, 50_000));
        assert!(!listen(&store, 2, 3_000, 239_999));
        assert!(listen(&store, 2, 4_000, 240_000));
        assert!(!listen(&store, 3, 5_000, 239_999));
        assert!(listen(&store, 3, 6_000, 240_000));
        assert!(!listen(&store, 4, 7_000, 0));
        assert!(listen(&store, 4, 8_000, 240_000));
        let history = store.history(20).unwrap();
        assert_eq!(history.iter().map(|r| r.started_at).collect::<Vec<_>>(), [8_000, 7_000, 6_000, 5_000, 4_000, 3_000, 2_000, 1_000]);
        assert_eq!(history.iter().map(|r| r.counted).collect::<Vec<_>>(), [true, false, true, false, true, false, true, false]);
        assert_eq!(store.history(2).unwrap().len(), 2);
        assert_eq!(store.most_played(0, 20).unwrap().iter().map(|r| (r.track.0, r.plays)).collect::<Vec<_>>(), [(4, 1), (3, 1), (2, 1), (1, 1)]);
        assert_eq!(store.most_played(6_000, 20).unwrap().len(), 2);
        let columns = store.load_columns().unwrap();
        assert_eq!(columns.plays, [1]);
        assert_eq!(columns.last_played, [2]);
        // A newer skip cannot move last played forward.
        assert!(!listen(&store, 1, 99_000, 1_000));
        assert_eq!(store.load_columns().unwrap().last_played, [2]);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn dormant_requires_five_counted_plays_and_a_last_older_than_180_days() {
        let (store, dir) = fixture();
        let now = DORMANT_MS + 1_000;
        for at in 1..5 { assert!(listen(&store, 1, at, 50_000)); }
        assert!(store.dormant_before(now - DORMANT_MS, 10).unwrap().is_empty());
        assert!(listen(&store, 1, 5, 50_000));
        assert!(!listen(&store, 1, now, 1_000));
        let dormant = store.dormant_before(now - DORMANT_MS, 10).unwrap();
        assert_eq!(dormant.len(), 1);
        assert_eq!((dormant[0].release, dormant[0].plays, dormant[0].last_played), (ReleaseId(1), 5, 5));
        assert!(listen(&store, 1, now - DORMANT_MS, 50_000));
        assert!(store.dormant_before(now - DORMANT_MS, 10).unwrap().is_empty(), "exactly 180 days is not older");
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn never_played_needs_a_playable_track_and_no_counted_play() {
        let (store, dir) = fixture();
        store.writer.write(|tx| tx.execute_batch("
            INSERT INTO release (id, title, rev) VALUES (2, 'No files', 1);
            INSERT INTO edition (id, release_id, rev) VALUES (2, 2, 1);
            INSERT INTO medium (id, edition_id, position) VALUES (2, 2, 1);
            INSERT INTO track (id, medium_id, position, recording_id, rev) VALUES (5, 2, 1, 2, 1);
        ")).unwrap();
        assert_eq!(store.never_played().unwrap(), [(ReleaseId(1), Some(1))], "a release without a present file is not offered");
        assert!(!listen(&store, 1, 1_000, 49_000));
        assert_eq!(store.never_played().unwrap().len(), 1, "a skip is not a play");
        assert!(listen(&store, 1, 2_000, 50_000));
        assert!(store.never_played().unwrap().is_empty());
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn source_preserves_release_and_source_less_history_does_not_duplicate_editions() {
        let (store, dir) = fixture();
        store.writer.write(|tx| tx.execute_batch("
            INSERT INTO release (id, title, rev) VALUES (2, 'Other release', 1);
            INSERT INTO edition (id, release_id, rev) VALUES (2, 2, 1);
            INSERT INTO medium (id, edition_id, position) VALUES (2, 2, 1);
            INSERT INTO track (id, medium_id, position, recording_id, rev) VALUES (5, 2, 1, 1, 1);
            INSERT INTO source (id, recording_id, track_id, kind, file_id, lossless, rev) VALUES (2, 1, 5, 'file', 1, 1, 1);
        ")).unwrap();
        let uid = ListenUid::new();
        store.start_listen(uid, RecordingId(1), Some(SourceId(2)), "local".into(), 2, None, store.device_id().unwrap()).unwrap();
        assert!(store.update_listen(uid, 50_000).unwrap());
        listen(&store, 1, 1, 50_000);
        let history = store.history(10).unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0].release, Some(ReleaseId(2)));
        assert_eq!(history[1].release, Some(ReleaseId(1)));
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
