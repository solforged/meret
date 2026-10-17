//! Track identity shared by scanning and the in-place copies migration.

use std::collections::HashMap;

use rusqlite::{Transaction, params};

use crate::search;

/// Removes a filename-style number only when it agrees with the tagged track.
/// A real title beginning with a year or another number is left alone.
pub fn clean_title(title: &str, position: u32) -> &str {
    match numbered_title(title) {
        Some((n, rest)) if position > 0 && n == position => rest,
        _ => title,
    }
}

fn numbered_title(title: &str) -> Option<(u32, &str)> {
    let title = title.trim();
    let end = title.bytes().take_while(u8::is_ascii_digit).count();
    if end == 0 {
        return None;
    }
    let number = title[..end].parse().ok()?;
    let rest = &title[end..];
    // Require a separator, not "1984" or "2Pac". Whitespace on its own is
    // deliberately insufficient: "1979 Smashing Pumpkins" can be a title.
    let rest = rest.trim_start();
    let rest = rest.strip_prefix(['-', '.', ')', ':', '–', '—'])?.trim_start();
    (!rest.is_empty()).then_some((number, rest))
}

fn title_key(title: &str) -> String {
    let title = numbered_title(title).map_or(title, |(_, rest)| rest);
    search::fold_str(title).chars().filter(|c| c.is_alphanumeric()).collect()
}

fn same_length(a: i64, b: i64) -> bool {
    a > 0 && b > 0 && a.abs_diff(b) <= 2_000
}

/// Finds an alternate copy on this exact medium. Numbered tracks need the
/// same position and title; two unnumbered tracks also need a known length
/// within two seconds. Numbered and unnumbered tracks never match.
pub fn matching_track(
    tx: &Transaction<'_>, medium: i64, position: u32, title: &str, length_ms: i64,
) -> rusqlite::Result<Option<(i64, i64)>> {
    let key = title_key(title);
    if key.is_empty() {
        return Ok(None);
    }
    let mut stmt = tx.prepare_cached(
        "SELECT t.id, t.recording_id, COALESCE(t.title, r.title), COALESCE(t.length_ms, r.length_ms, 0)
         FROM track t JOIN recording r ON r.id = t.recording_id
         WHERE t.medium_id = ?1 AND t.position = ?2 ORDER BY t.id",
    )?;
    for row in stmt.query_map(params![medium, position], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?, r.get::<_, i64>(3)?))
    })? {
        let (track, recording, name, length) = row?;
        if title_key(&name) == key && (position > 0 || same_length(length_ms, length)) {
            return Ok(Some((track, recording)));
        }
    }
    Ok(None)
}

struct Candidate {
    track: i64,
    recording: i64,
    length_ms: i64,
}

/// Migration 0006. Keep the oldest track and its recording; all file/source
/// IDs, history, graph references and claims survive the merge.
pub(crate) fn merge_existing(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let rows = tx.prepare(
        "SELECT t.id, t.recording_id, t.medium_id, t.position, COALESCE(t.title, r.title),
                COALESCE(t.length_ms, r.length_ms, 0)
         FROM track t JOIN recording r ON r.id = t.recording_id ORDER BY t.id",
    )?.query_map([], |r| {
        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, u32>(3)?,
            r.get::<_, String>(4)?, r.get::<_, i64>(5)?))
    })?.collect::<rusqlite::Result<Vec<_>>>()?;
    let rev = crate::next_rev(tx)?;
    let mut survivors: HashMap<(i64, u32, String), Vec<Candidate>> = HashMap::new();
    for (track, recording, medium, position, title, length) in rows {
        let cleaned = clean_title(&title, position);
        if cleaned != title {
            tx.execute("UPDATE track SET title = ?2, rev = ?3 WHERE id = ?1", params![track, cleaned, rev])?;
            let recording_title: String = tx.query_row("SELECT title FROM recording WHERE id = ?1", [recording], |r| r.get(0))?;
            let cleaned_recording = clean_title(&recording_title, position);
            if cleaned_recording != recording_title {
                tx.execute("UPDATE recording SET title = ?2, rev = ?3 WHERE id = ?1", params![recording, cleaned_recording, rev])?;
            }
            search::index_recording(tx, recording)?;
        }
        let key = title_key(cleaned);
        if key.is_empty() {
            continue;
        }
        let candidates = survivors.entry((medium, position, key)).or_default();
        let Some(keep) = candidates.iter().find(|copy| position > 0 || same_length(length, copy.length_ms)) else {
            candidates.push(Candidate { track, recording, length_ms: length });
            continue;
        };
        let (keep_track, keep_recording) = (keep.track, keep.recording);
        tx.execute("UPDATE source SET track_id = ?2, recording_id = ?3, rev = ?4 WHERE track_id = ?1",
            params![track, keep_track, keep_recording, rev])?;
        merge_entity(tx, 5, track, keep_track, rev)?;
        tx.execute("DELETE FROM track WHERE id = ?1", [track])?;
        let used: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM track WHERE recording_id = ?1)", [recording], |r| r.get(0))?;
        if recording != keep_recording && !used {
            tx.execute("UPDATE source SET recording_id = ?2, rev = ?3 WHERE recording_id = ?1", params![recording, keep_recording, rev])?;
            tx.execute("UPDATE listen SET recording_id = ?2 WHERE recording_id = ?1", params![recording, keep_recording])?;
            tx.execute("UPDATE resume SET recording_id = ?2 WHERE recording_id = ?1", params![recording, keep_recording])?;
            tx.execute("INSERT OR IGNORE INTO recording_context SELECT ?2, context_id, provenance_id FROM recording_context WHERE recording_id = ?1",
                params![recording, keep_recording])?;
            tx.execute("DELETE FROM recording_context WHERE recording_id = ?1", [recording])?;
            tx.execute(
                "INSERT INTO analysis SELECT ?2, loudness_lufs, peak_db, dr, bpm, key, body, embedding_row, analysed_at, version
                 FROM analysis WHERE recording_id = ?1
                 ON CONFLICT(recording_id) DO UPDATE SET
                    loudness_lufs = COALESCE(analysis.loudness_lufs, excluded.loudness_lufs),
                    peak_db = COALESCE(analysis.peak_db, excluded.peak_db), dr = COALESCE(analysis.dr, excluded.dr),
                    bpm = COALESCE(analysis.bpm, excluded.bpm), key = COALESCE(analysis.key, excluded.key),
                    body = COALESCE(analysis.body, excluded.body), embedding_row = COALESCE(analysis.embedding_row, excluded.embedding_row)",
                params![recording, keep_recording],
            )?;
            tx.execute("DELETE FROM analysis WHERE recording_id = ?1", [recording])?;
            tx.execute(
                "UPDATE recording SET work_id = COALESCE(work_id, (SELECT work_id FROM recording WHERE id = ?2)),
                    recorded = COALESCE(recorded, (SELECT recorded FROM recording WHERE id = ?2)),
                    venue = COALESCE(venue, (SELECT venue FROM recording WHERE id = ?2)), rev = ?3 WHERE id = ?1",
                params![keep_recording, recording, rev],
            )?;
            merge_entity(tx, 2, recording, keep_recording, rev)?;
            tx.execute("DELETE FROM search WHERE entity_kind = 2 AND entity_id = ?1", [recording])?;
            tx.execute("DELETE FROM recording WHERE id = ?1", [recording])?;
        } else if recording != keep_recording {
            search::index_recording(tx, recording)?;
        }
        search::index_recording(tx, keep_recording)?;
    }
    Ok(())
}

fn merge_entity(tx: &Transaction<'_>, kind: i64, old: i64, keep: i64, rev: i64) -> rusqlite::Result<()> {
    for table in ["credit", "note"] {
        tx.execute(&format!("UPDATE {table} SET subject_id = ?3 WHERE subject_kind = ?1 AND subject_id = ?2"), params![kind, old, keep])?;
    }
    // Keep distinct claims but not identical credits from the two copies.
    tx.execute(
        "DELETE FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND id NOT IN
         (SELECT MIN(id) FROM credit WHERE subject_kind = ?1 AND subject_id = ?2
          GROUP BY agent_id, role, detail, sort, provenance_id)", params![kind, keep],
    )?;
    tx.execute("UPDATE credit SET rev = ?3 WHERE subject_kind = ?1 AND subject_id = ?2", params![kind, keep, rev])?;
    tx.execute("INSERT OR IGNORE INTO entity_artwork SELECT ?1, ?3, hash FROM entity_artwork WHERE entity_kind = ?1 AND entity_id = ?2", params![kind, old, keep])?;
    tx.execute("DELETE FROM entity_artwork WHERE entity_kind = ?1 AND entity_id = ?2", params![kind, old])?;
    tx.execute("UPDATE external_id SET entity_id = ?3 WHERE entity_kind = ?1 AND entity_id = ?2", params![kind, old, keep])?;
    for direction in ["from", "to"] {
        tx.execute(&format!("UPDATE edge SET {direction}_id = ?3, rev = ?4 WHERE {direction}_kind = ?1 AND {direction}_id = ?2"), params![kind, old, keep, rev])?;
    }
    for table in ["stop", "crate_item", "want"] {
        tx.execute(&format!("UPDATE {table} SET entity_id = CAST(?3 AS TEXT) WHERE entity_kind = ?1 AND entity_id = CAST(?2 AS TEXT)"), params![kind, old, keep])?;
    }
    tx.execute(
        "INSERT INTO resume SELECT subject_kind, ?3, recording_id, position_ms, updated_at, device FROM resume
         WHERE subject_kind = ?1 AND subject_id = ?2
         ON CONFLICT(subject_kind, subject_id) DO UPDATE SET recording_id = excluded.recording_id,
           position_ms = excluded.position_ms, updated_at = excluded.updated_at, device = excluded.device
         WHERE excluded.updated_at > resume.updated_at", params![kind, old, keep],
    )?;
    tx.execute("DELETE FROM resume WHERE subject_kind = ?1 AND subject_id = ?2", params![kind, old])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_prefixes_are_not_real_numbers_in_titles() {
        assert_eq!(clean_title("01 - Térratus", 1), "Térratus");
        assert_eq!(clean_title("1 - Terratus", 2), "1 - Terratus");
        assert_eq!(clean_title("1979", 1), "1979");
        assert_eq!(clean_title("2Pac", 2), "2Pac");
        assert_eq!(clean_title("1979 Smashing Pumpkins", 1979), "1979 Smashing Pumpkins");
        assert_eq!(title_key("01 - TÉRRA-tus!"), title_key("Terratus"));
    }

    #[test]
    fn identity_boundaries_are_medium_number_title_and_known_length() {
        let mut c = rusqlite::Connection::open_in_memory().unwrap();
        crate::search::register(&c).unwrap();
        crate::migrate::run(&mut c).unwrap();
        let tx = c.transaction().unwrap();
        tx.execute_batch("INSERT INTO release(id,title,rev) VALUES(1,'R',1);
            INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
            INSERT INTO medium(id,edition_id,position) VALUES(1,1,1),(2,1,2);
            INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'Térratus',10000,1),(2,'Unknown',10000,1);
            INSERT INTO track(id,medium_id,position,recording_id,title,length_ms,rev)
                VALUES(1,1,1,1,'Térratus',10000,1),(2,1,0,2,'Unknown',10000,1);").unwrap();
        assert_eq!(matching_track(&tx, 1, 1, "01 - TERRA-tus!", 30000).unwrap(), Some((1, 1)));
        assert_eq!(matching_track(&tx, 1, 2, "Terratus", 10000).unwrap(), None);
        assert_eq!(matching_track(&tx, 2, 1, "Terratus", 10000).unwrap(), None);
        assert_eq!(matching_track(&tx, 1, 0, "Terratus", 10000).unwrap(), None);
        assert_eq!(matching_track(&tx, 1, 0, "unknown", 12000).unwrap(), Some((2, 2)));
        assert_eq!(matching_track(&tx, 1, 0, "unknown", 12001).unwrap(), None);
        assert_eq!(matching_track(&tx, 1, 0, "unknown", 8000).unwrap(), Some((2, 2)));
        assert_eq!(matching_track(&tx, 1, 0, "unknown", 7999).unwrap(), None);
        assert_eq!(matching_track(&tx, 1, 0, "unknown", 0).unwrap(), None);
    }
}
