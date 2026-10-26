//! Canonical local-tag people, the data part of migration 0007, and the
//! repair that splits names once joined by `/`.

use meret_model::credit::{clean_name, name_key, split_credit};
use rusqlite::{OptionalExtension, Transaction, params};

use crate::search;

pub fn agent(tx: &Transaction<'_>, name: &str, rev: i64) -> rusqlite::Result<i64> {
    let key = name_key(name);
    if let Some(id) = tx.query_row("SELECT id FROM agent WHERE normalized_name = ?1 ORDER BY id LIMIT 1", [&key], |r| r.get(0)).optional()? {
        return Ok(id);
    }
    let id = tx.query_row(
        "INSERT INTO agent (kind, name, normalized_name, rev) VALUES (0, ?1, ?2, ?3) RETURNING id",
        params![clean_name(name), key, rev], |r| r.get(0),
    )?;
    search::index_agent(tx, id)?;
    Ok(id)
}

/// Local-tag credits stored under one joined name before `/` split names
/// ("Roger Briggs/Mark Cromer") move to each person, joining anyone already
/// known by that name. It runs at every open and finds nothing once done.
pub(crate) fn split_joined(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let joined = tx.prepare("SELECT id, name FROM agent WHERE name LIKE '%/%'")?
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?
        .into_iter().filter(|(_, name)| split_credit(name).len() > 1).collect::<Vec<_>>();
    if joined.is_empty() {
        return Ok(());
    }
    let rev = crate::next_rev(tx)?;
    let (mut recordings, mut releases) = (vec![], vec![]);
    for (joined_id, name) in joined {
        let credits = tx.prepare(
            "SELECT c.id, c.subject_kind, c.subject_id, c.role, c.detail, c.sort, c.provenance_id
             FROM credit c LEFT JOIN provenance p ON p.id = c.provenance_id
             WHERE c.agent_id = ?1 AND (p.source = 'local_tags' OR p.id IS NULL)"
        )?.query_map([joined_id], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, String>(3)?,
            r.get::<_, Option<String>>(4)?, r.get::<_, i64>(5)?, r.get::<_, Option<i64>>(6)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
        let people = split_credit(&name).iter().map(|person| agent(tx, person, rev)).collect::<rusqlite::Result<Vec<_>>>()?;
        for (id, kind, subject, role, detail, sort, provenance) in credits {
            tx.execute("DELETE FROM credit WHERE id = ?1", [id])?;
            for (i, person) in people.iter().enumerate() {
                tx.execute(
                    "INSERT INTO credit (subject_kind, subject_id, agent_id, role, detail, sort, provenance_id, rev)
                     SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8 WHERE NOT EXISTS (
                        SELECT 1 FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND agent_id = ?3 AND role = ?4 AND provenance_id IS ?7)",
                    params![kind, subject, person, role, detail, sort * 1000 + i as i64, provenance, rev],
                )?;
            }
            match kind {
                2 => recordings.push(subject),
                3 => releases.push(subject),
                _ => {}
            }
        }
        // The joined name goes only when nothing else points at it.
        let unused = tx.query_row(
            "SELECT NOT EXISTS (SELECT 1 FROM credit WHERE agent_id = ?1)
                AND NOT EXISTS (SELECT 1 FROM external_id WHERE entity_kind = 6 AND entity_id = ?1)
                AND NOT EXISTS (SELECT 1 FROM edge WHERE (from_kind = 6 AND from_id = ?1) OR (to_kind = 6 AND to_id = ?1))",
            [joined_id], |r| r.get::<_, bool>(0),
        )?;
        if unused {
            tx.execute("DELETE FROM search WHERE entity_kind = 6 AND entity_id = ?1", [joined_id])?;
            tx.execute("DELETE FROM agent WHERE id = ?1", [joined_id])?;
        }
        for person in people { search::index_agent(tx, person)?; }
    }
    for id in recordings { search::index_recording(tx, id)?; }
    for id in releases { search::index_release(tx, id)?; }
    Ok(())
}

pub(crate) fn migrate(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let rev = crate::next_rev(tx)?;
    let agents = tx.prepare("SELECT id, name FROM agent ORDER BY id")?
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
    for (id, name) in agents {
        tx.execute("UPDATE agent SET normalized_name = ?2, name = ?3, rev = ?4 WHERE id = ?1", params![id, name_key(&name), clean_name(&name), rev])?;
    }
    let credits = tx.prepare(
        "SELECT c.id, c.subject_kind, c.subject_id, a.name, c.role, c.sort, c.provenance_id
         FROM credit c JOIN agent a ON a.id = c.agent_id LEFT JOIN provenance p ON p.id = c.provenance_id
         WHERE ((c.subject_kind = 2 AND c.role = 'artist') OR (c.subject_kind = 3 AND c.role = 'album_artist'))
           AND (p.source = 'local_tags' OR p.id IS NULL) ORDER BY c.id"
    )?.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, String>(3)?,
        r.get::<_, String>(4)?, r.get::<_, i64>(5)?, r.get::<_, Option<i64>>(6)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
    for (id, kind, subject, written, role, sort, provenance) in credits {
        tx.execute("DELETE FROM credit WHERE id = ?1", [id])?;
        for (i, name) in split_credit(&written).iter().enumerate() {
            let person = agent(tx, name, rev)?;
            tx.execute(
                "INSERT INTO credit (subject_kind, subject_id, agent_id, role, sort, provenance_id, rev)
                 SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7 WHERE NOT EXISTS (
                    SELECT 1 FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND agent_id = ?3 AND role = ?4 AND provenance_id IS ?6)",
                params![kind, subject, person, role, sort * 1000 + i as i64, provenance, rev],
            )?;
        }
    }
    // Merge remaining case/whitespace aliases, including credits from sources
    // other than local tags, without interpreting their authored boundaries.
    tx.execute_batch(
        "UPDATE credit SET agent_id = (SELECT MIN(a.id) FROM agent a WHERE a.normalized_name =
            (SELECT normalized_name FROM agent WHERE id = credit.agent_id));
         DELETE FROM credit WHERE id NOT IN (SELECT MIN(id) FROM credit
            GROUP BY subject_kind, subject_id, agent_id, role, COALESCE(detail, ''), provenance_id);
         DELETE FROM search WHERE entity_kind = 6 AND entity_id IN
            (SELECT id FROM agent WHERE NOT EXISTS (SELECT 1 FROM credit WHERE credit.agent_id = agent.id));
         DELETE FROM agent WHERE NOT EXISTS (SELECT 1 FROM credit WHERE credit.agent_id = agent.id);"
    )?;
    for (table, index) in [("agent", search::index_agent as fn(&Transaction<'_>, i64) -> rusqlite::Result<()>),
        ("recording", search::index_recording), ("release", search::index_release)] {
        let ids = tx.prepare(&format!("SELECT id FROM {table}"))?.query_map([], |r| r.get::<_, i64>(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
        for id in ids { index(tx, id)?; }
    }
    Ok(())
}
