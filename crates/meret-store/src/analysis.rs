//! Persisted recording analysis and the track patches published after a write.

use std::path::PathBuf;

use meret_model::{RecordingId, TrackId};
use rusqlite::OptionalExtension;

use crate::library::PREFERRED_RECORDING_SOURCE;
use crate::{Result, Store, next_rev};

pub const ANALYSIS_VERSION: i64 = 1;

#[derive(Clone, Debug, PartialEq)]
pub struct AnalysisRow {
    pub recording_id: RecordingId,
    pub loudness_lufs: Option<f64>,
    pub peak_db: Option<f64>,
    pub dr: Option<u8>,
    pub body: Vec<u8>,
    /// Unix milliseconds.
    pub analysed_at: i64,
    pub version: i64,
}

/// Effective track values, including an edition's DR when its recording has none.
#[derive(Clone, Debug, PartialEq)]
pub struct AnalysisPatch {
    pub track: TrackId,
    pub dr: Option<u8>,
    pub loudness_lufs: Option<f64>,
}

impl Store {
    /// Recordings that can be decoded now and have no current analysis.
    pub fn analysis_candidates(&self) -> Result<Vec<RecordingId>> {
        self.read(|c| {
            c.prepare_cached(
                "SELECT DISTINCT s.recording_id FROM source s
                 JOIN file f ON f.id = s.file_id JOIN root ro ON ro.id = f.root_id
                 LEFT JOIN analysis a ON a.recording_id = s.recording_id AND a.version = ?1
                 WHERE s.recording_id IS NOT NULL AND s.kind = 'file'
                   AND f.state = 'present' AND ro.state = 'online'
                   AND a.recording_id IS NULL ORDER BY s.recording_id",
            )?.query_map([ANALYSIS_VERSION], |r| Ok(RecordingId(r.get(0)?)))?
                .collect()
        })
    }

    /// The best online file across all tracks of this recording.
    pub fn analysis_file(&self, recording: RecordingId) -> Result<Option<PathBuf>> {
        self.read(|c| {
            c.query_row(
                &format!("SELECT ro.path, f.rel_path FROM source s
                          JOIN file f ON f.id = s.file_id JOIN root ro ON ro.id = f.root_id
                          WHERE s.id = {PREFERRED_RECORDING_SOURCE}"),
                [recording.0],
                |r| Ok(PathBuf::from(r.get::<_, String>(0)?).join(r.get::<_, String>(1)?)),
            ).optional()
        })
    }

    /// Saves one recording and completes any editions whose present tracks are analysed.
    pub fn save_analysis(&self, row: AnalysisRow) -> Result<Vec<AnalysisPatch>> {
        self.writer.write(move |tx| {
            tx.execute(
                "INSERT INTO analysis (recording_id, loudness_lufs, peak_db, dr, body, analysed_at, version)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(recording_id) DO UPDATE SET
                     loudness_lufs = excluded.loudness_lufs, peak_db = excluded.peak_db,
                     dr = excluded.dr, body = excluded.body, analysed_at = excluded.analysed_at,
                     version = excluded.version",
                rusqlite::params![row.recording_id.0, row.loudness_lufs, row.peak_db, row.dr,
                    row.body, row.analysed_at, row.version],
            )?;
            let editions = tx.prepare_cached(
                "SELECT DISTINCT e.id, e.dr FROM track t JOIN medium m ON m.id = t.medium_id
                 JOIN edition e ON e.id = m.edition_id WHERE t.recording_id = ?1",
            )?.query_map([row.recording_id.0], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, Option<u8>>(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let mut changed = Vec::new();
            for (edition, previous_dr) in editions {
                // Offline present files still belong to the edition. They must be
                // analysed before its album DR is complete; missing files do not.
                let (total, analysed, mean): (i64, i64, Option<f64>) = tx.query_row(
                    "SELECT COUNT(*), COUNT(a.recording_id), AVG(a.dr) FROM track t
                     JOIN medium m ON m.id = t.medium_id
                     LEFT JOIN analysis a ON a.recording_id = t.recording_id AND a.version = ?2
                     WHERE m.edition_id = ?1 AND EXISTS (
                         SELECT 1 FROM source s JOIN file f ON f.id = s.file_id
                         JOIN root ro ON ro.id = f.root_id WHERE s.track_id = t.id
                         AND s.kind = 'file' AND f.state = 'present' AND ro.state <> 'removed')",
                    (edition, ANALYSIS_VERSION),
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )?;
                if total != 0 && analysed == total {
                    let dr = mean.map(|value| value.round() as u8);
                    if dr != previous_dr {
                        let rev = next_rev(tx)?;
                        tx.execute("UPDATE edition SET dr = ?2, rev = ?3 WHERE id = ?1", (edition, dr, rev))?;
                        changed.push(edition);
                    }
                }
            }
            let edition_clause = if changed.is_empty() {
                String::new()
            } else {
                format!(" UNION SELECT t2.id FROM medium m2 JOIN track t2 ON t2.medium_id = m2.id
                          WHERE m2.edition_id IN ({})", vec!["?"; changed.len()].join(","))
            };
            let sql = format!(
                "SELECT t.id, COALESCE(a.dr, e.dr), a.loudness_lufs FROM track t
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 LEFT JOIN analysis a ON a.recording_id = t.recording_id AND a.version = {ANALYSIS_VERSION}
                 WHERE t.id IN (SELECT id FROM track WHERE recording_id = ?{edition_clause}) ORDER BY t.id",
            );
            tx.prepare(&sql)?.query_map(
                rusqlite::params_from_iter(std::iter::once(row.recording_id.0).chain(changed)),
                |r| Ok(AnalysisPatch { track: TrackId(r.get(0)?), dr: r.get(1)?, loudness_lufs: r.get(2)? }),
            )?.collect()
        })
    }

    /// Current recording analysis for a track, independent of file availability.
    pub fn track_analysis(&self, track: TrackId) -> Result<Option<AnalysisRow>> {
        self.read(|c| {
            c.query_row(
                "SELECT a.recording_id, a.loudness_lufs, a.peak_db, a.dr, COALESCE(a.body, X''), a.analysed_at, a.version
                 FROM track t JOIN analysis a ON a.recording_id = t.recording_id
                 WHERE t.id = ?1 AND a.version = ?2",
                (track.0, ANALYSIS_VERSION),
                |r| Ok(AnalysisRow {
                    recording_id: RecordingId(r.get(0)?), loudness_lufs: r.get(1)?, peak_db: r.get(2)?,
                    dr: r.get(3)?, body: r.get(4)?, analysed_at: r.get(5)?, version: r.get(6)?,
                }),
            ).optional()
        })
    }

    /// Mean integrated loudness of analysed tracks in this track's edition.
    pub fn album_loudness(&self, track: TrackId) -> Result<Option<f64>> {
        self.read(|c| {
            c.query_row(
                "SELECT AVG(a.loudness_lufs) FROM track selected
                 JOIN medium selected_medium ON selected_medium.id = selected.medium_id
                 JOIN medium m ON m.edition_id = selected_medium.edition_id
                 JOIN track t ON t.medium_id = m.id
                 JOIN analysis a ON a.recording_id = t.recording_id AND a.version = ?2
                 WHERE selected.id = ?1",
                (track.0, ANALYSIS_VERSION), |r| r.get(0),
            )
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use meret_model::ReleaseId;

    fn fixture() -> (Store, PathBuf) {
        let dir = std::env::temp_dir().join(format!("meret-analysis-{}", ulid::Ulid::generate()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO release(id,title,rev) VALUES(1,'First',1),(2,'Second',1);
                 INSERT INTO edition(id,release_id,dr,is_default,rev) VALUES(1,1,8,1,1),(2,2,7,1,1);
                 INSERT INTO medium(id,edition_id,position) VALUES(1,1,1),(2,2,1);
                 INSERT INTO recording(id,title,rev) VALUES(1,'A',1),(2,'B',1),(3,'C',1),(4,'D',1),(5,'Missing',1);
                 INSERT INTO track(id,medium_id,position,recording_id,rev) VALUES
                     (1,1,1,1,1),(2,1,2,2,1),(3,1,3,3,1),(4,2,1,1,1),(5,2,2,4,1),(6,1,4,5,1);
                 INSERT INTO root(id,label,path,kind,state) VALUES
                     (1,'Music','/music','local','online'),(2,'Archive','/archive','local','offline');
                 INSERT INTO file(id,root_id,rel_path,size,mtime_ns,state,rev) VALUES
                     (1,1,'a.mp3',1,1,'present',1),(2,1,'a.flac',1,1,'present',1),
                     (3,1,'b.flac',1,1,'present',1),(4,1,'shared.flac',1,1,'present',1),
                     (5,2,'d.flac',1,1,'present',1),(6,1,'missing.flac',1,1,'missing',1),
                     (7,1,'c.flac',1,1,'present',1),(8,2,'a-hires.flac',1,1,'present',1);
                 INSERT INTO source(id,recording_id,track_id,kind,file_id,codec,lossless,bits,sample_rate,rev) VALUES
                     (1,1,1,'file',1,'MP3',0,NULL,44100,1),(2,1,1,'file',2,'FLAC',1,16,44100,1),
                     (3,2,2,'file',3,'FLAC',1,16,44100,1),(4,1,4,'file',4,'FLAC',1,24,96000,1),
                     (5,4,5,'file',5,'FLAC',1,24,96000,1),(6,5,6,'file',6,'FLAC',1,16,44100,1),
                     (7,3,3,'file',7,'FLAC',1,16,44100,1),(8,1,1,'file',8,'FLAC',1,24,192000,1);",
            )?;
            Ok(())
        }).unwrap();
        (store, dir)
    }

    fn analysis(recording: i64, loudness_lufs: Option<f64>, dr: Option<u8>) -> AnalysisRow {
        AnalysisRow { recording_id: RecordingId(recording), loudness_lufs, peak_db: Some(-2.5),
            dr, body: vec![1, 2, 3, recording as u8], analysed_at: 1234, version: ANALYSIS_VERSION }
    }

    #[test]
    fn candidates_require_online_present_files_and_current_version() {
        let (store, dir) = fixture();
        assert_eq!(store.analysis_candidates().unwrap(), vec![RecordingId(1), RecordingId(2), RecordingId(3)]);
        assert_eq!(store.analysis_file(RecordingId(1)).unwrap(), Some(PathBuf::from("/music/shared.flac")));
        assert_eq!(store.analysis_file(RecordingId(4)).unwrap(), None);
        assert_eq!(store.analysis_file(RecordingId(5)).unwrap(), None);
        store.writer.write(|tx| tx.execute_batch(
            "INSERT INTO recording(id,title,rev) VALUES(6,'Without an edition',1);
             INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES(9,1,'loose.flac',1,1,1);
             INSERT INTO source(id,recording_id,kind,file_id,codec,lossless,rev) VALUES(9,6,'file',9,'FLAC',1,1);",
        )).unwrap();
        assert_eq!(store.analysis_file(RecordingId(6)).unwrap(), Some(PathBuf::from("/music/loose.flac")));
        let mut stale = analysis(1, Some(-20.0), Some(10));
        stale.version = 0;
        store.save_analysis(stale).unwrap();
        store.save_analysis(analysis(2, Some(-14.0), Some(12))).unwrap();
        assert_eq!(store.analysis_candidates().unwrap(), vec![RecordingId(1), RecordingId(3), RecordingId(6)]);
        assert!(store.track_analysis(TrackId(1)).unwrap().is_none());
        store.writer.write(|tx| tx.execute("UPDATE root SET state = 'offline'", [])).unwrap();
        assert!(store.analysis_candidates().unwrap().is_empty());
        assert!(store.analysis_file(RecordingId(1)).unwrap().is_none());
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn saved_analysis_patches_recordings_and_completed_edition_fallbacks() {
        let (store, dir) = fixture();
        let mut columns = store.load_columns().unwrap();
        let first = analysis(1, Some(-20.54), Some(12));
        let patches = store.save_analysis(first.clone()).unwrap();
        assert_eq!(patches.iter().map(|p| p.track).collect::<Vec<_>>(), vec![TrackId(1), TrackId(4)]);
        columns.patch_analysis(&patches);
        assert_eq!(store.track_analysis(TrackId(4)).unwrap(), Some(first));
        let first_row = columns.track.iter().position(|&id| id == TrackId(1)).unwrap();
        assert_eq!((columns.dr[first_row], columns.loudness[first_row]), (12, -205));
        assert_eq!(store.release_page(ReleaseId(1)).unwrap().unwrap().dr, Some(8));
        columns.patch_analysis(&store.save_analysis(analysis(2, Some(-12.0), Some(11))).unwrap());
        assert_eq!(store.release_page(ReleaseId(1)).unwrap().unwrap().dr, Some(8), "wait for every present track");
        let patches = store.save_analysis(analysis(3, Some(-18.0), None)).unwrap();
        assert_eq!(patches.iter().map(|p| p.track).collect::<Vec<_>>(), vec![TrackId(1), TrackId(2), TrackId(3), TrackId(6)]);
        columns.patch_analysis(&patches);
        let page = store.release_page(ReleaseId(1)).unwrap().unwrap();
        assert_eq!(page.dr, Some(12), "album DR rounds the mean and ignores unknown track DR");
        assert!((page.loudness_lufs.unwrap() - (-20.54 - 12.0 - 18.0) / 3.0).abs() < 1e-10);
        let third = store.track_rows(&[TrackId(3), TrackId(6)]).unwrap();
        assert_eq!(third[0].dr, Some(12));
        assert_eq!(third[0].loudness, Some(-18.0));
        assert_eq!(third[1].dr, Some(12), "missing tracks use the completed edition fallback");
        assert_eq!(store.release_page(ReleaseId(2)).unwrap().unwrap().dr, Some(7), "offline present tracks still need analysis");
        columns.patch_analysis(&store.save_analysis(analysis(4, None, Some(14))).unwrap());
        assert_eq!(store.release_page(ReleaseId(2)).unwrap().unwrap().dr, Some(13));
        let reloaded = store.load_columns().unwrap();
        assert_eq!(columns.dr, reloaded.dr);
        assert_eq!(columns.loudness, reloaded.loudness);
        let mut replacement = analysis(1, Some(-19.0), Some(10));
        replacement.analysed_at = 2345;
        store.save_analysis(replacement.clone()).unwrap();
        assert_eq!(store.track_analysis(TrackId(1)).unwrap(), Some(replacement));
        assert_eq!(store.release_page(ReleaseId(1)).unwrap().unwrap().dr, Some(11));
        drop(store);
        let reopened = Store::open(&dir.join("library.db")).unwrap();
        assert_eq!(reopened.track_analysis(TrackId(1)).unwrap().unwrap().analysed_at, 2345);
        drop(reopened);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn playback_reads_album_mean_with_unknowns_and_edition_boundaries() {
        let (store, dir) = fixture();
        assert_eq!(store.album_loudness(TrackId(1)).unwrap(), None);
        assert_eq!(store.album_loudness(TrackId(999)).unwrap(), None);
        assert_eq!(store.track_analysis(TrackId(999)).unwrap(), None);
        store.save_analysis(analysis(1, Some(-22.0), Some(12))).unwrap();
        store.save_analysis(analysis(2, Some(-14.0), Some(10))).unwrap();
        store.save_analysis(analysis(3, None, None)).unwrap();
        store.save_analysis(analysis(4, Some(-10.0), Some(8))).unwrap();
        assert_eq!(store.album_loudness(TrackId(1)).unwrap(), Some(-18.0));
        assert_eq!(store.album_loudness(TrackId(3)).unwrap(), Some(-18.0));
        assert_eq!(store.album_loudness(TrackId(4)).unwrap(), Some(-16.0));
        assert_eq!(store.track_analysis(TrackId(4)).unwrap().unwrap().peak_db, Some(-2.5));
        assert_eq!(store.track_analysis(TrackId(3)).unwrap().unwrap().loudness_lufs, None);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
