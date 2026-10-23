use std::collections::HashMap;

use meret_graph::{Action, Trail, Via};
use meret_graph::trail::Stop;
use meret_model::*;
use rusqlite::{Connection, Row, params};
use serde::{Serialize, de::DeserializeOwned};

use crate::{Result, Store};

#[derive(Clone, Debug)]
pub struct TrailSummary {
    pub uid: TrailUid,
    pub name: Option<String>,
    pub root: EntityRef,
    pub leaf: EntityRef,
    pub root_query: Option<String>,
    pub stops: u32,
    pub branches: u32,
    pub created_at: i64,
    pub kept: bool,
    pub played: u32,
    pub wanted: u32,
}

impl Store {
    /// Saves a snapshot through the writer, with stops remaining append-only.
    /// Existing actions retain their first recorded timestamp.
    pub fn save_trail(&self, trail: &Trail, position: usize, departure: usize) -> Result<()> {
        self.save_trail_snapshot(trail.clone(), position, departure)
    }

    /// Owned snapshots let the core release its lock without copying twice.
    pub fn save_trail_snapshot(&self, trail: Trail, position: usize, departure: usize) -> Result<()> {
        let device = self.device_id()?;
        let now = now_ms();
        let trail_uid = trail.uid.to_string();
        self.writer.write(move |tx| {
            tx.execute(
                "INSERT INTO trail(uid,name,root_query,kept,created_at,current_stop,device,position,departure_stop,updated_at)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
                 ON CONFLICT(uid) DO UPDATE SET name=excluded.name,root_query=excluded.root_query,
                    kept=excluded.kept,current_stop=excluded.current_stop,position=excluded.position,
                    departure_stop=excluded.departure_stop,updated_at=excluded.updated_at",
                params![trail_uid, trail.name, trail.root_query, trail.kept, trail.stop(0).opened_at,
                    trail.stop(trail.current()).uid.to_string(), device, position as i64,
                    trail.stop(departure).uid.to_string(), now],
            )?;
            let mut stop_stmt = tx.prepare_cached(
                "INSERT INTO stop(uid,trail_uid,parent_uid,entity_kind,entity_id,via_kind,via_source,opened_at,dwell_ms,device,pruned)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
                 ON CONFLICT(uid) DO UPDATE SET opened_at=excluded.opened_at,dwell_ms=excluded.dwell_ms,pruned=excluded.pruned",
            )?;
            let mut action_stmt = tx.prepare_cached(
                "INSERT INTO stop_action(stop_uid,action,at)
                 SELECT ?1,?2,?3 WHERE NOT EXISTS(SELECT 1 FROM stop_action WHERE stop_uid=?1 AND action=?2)",
            )?;
            for stop in trail.stops() {
                let uid = stop.uid.to_string();
                stop_stmt.execute(params![uid, trail_uid, stop.parent.map(|i| trail.stop(i).uid.to_string()),
                    stop.entity.kind() as i64, entity_id(stop.entity), stop.via.as_ref().map(|v| enum_name(&v.kind)),
                    stop.via.as_ref().map(|v| &v.source), stop.opened_at, stop.dwell_ms, device, stop.pruned])?;
                for action in &stop.actions {
                    action_stmt.execute(params![uid, enum_name(action), now])?;
                }
            }
            Ok(())
        })
    }

    /// History order is independent of stop visit times. SQLite rowid preserves
    /// stop insertion order even when revisiting a stop changes `opened_at`.
    pub fn load_trails(&self) -> Result<Vec<(Trail, usize)>> {
        self.read(|c| {
            let mut stmt = c.prepare("SELECT uid,name,root_query,kept,current_stop,departure_stop FROM trail ORDER BY position,rowid")?;
            let mut rows = stmt.query([])?;
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let uid: String = row.get(0)?;
                let stops = load_stops(c, &uid)?;
                if stops.is_empty() {
                    continue; // Older schema allowed an empty trail row.
                }
                let current_uid: Option<String> = row.get(4)?;
                let departure_uid: Option<String> = row.get(5)?;
                let current_uid = current_uid.as_deref().map(parse).transpose()?.map(StopUid);
                let departure_uid = departure_uid.as_deref().map(parse).transpose()?.map(StopUid);
                let current = stops.iter().position(|s| Some(s.uid) == current_uid).unwrap_or(0);
                let departure = stops.iter().position(|s| Some(s.uid) == departure_uid).unwrap_or(current);
                let trail = Trail::restore(TrailUid(parse(&uid)?), row.get(1)?, row.get(2)?, row.get(3)?, stops, current, now_ms());
                out.push((trail, departure));
            }
            Ok(out)
        })
    }

    pub fn trail_summaries(&self, limit: u32) -> Result<Vec<TrailSummary>> {
        self.read(|c| {
            let mut stmt = c.prepare(
                "SELECT t.uid,t.name,t.root_query,t.created_at,t.kept,
                    r.entity_kind,r.entity_id,l.entity_kind,l.entity_id,
                    (SELECT COUNT(*) FROM stop s WHERE s.trail_uid=t.uid AND s.pruned=0),
                    (SELECT COUNT(*) FROM stop s WHERE s.trail_uid=t.uid AND s.pruned=0
                        AND NOT EXISTS(SELECT 1 FROM stop child WHERE child.parent_uid=s.uid AND child.pruned=0)),
                    (SELECT COUNT(*) FROM stop_action a JOIN stop s ON s.uid=a.stop_uid WHERE s.trail_uid=t.uid AND a.action='played'),
                    (SELECT COUNT(*) FROM stop_action a JOIN stop s ON s.uid=a.stop_uid WHERE s.trail_uid=t.uid AND a.action='wanted')
                 FROM trail t JOIN stop r ON r.rowid=(SELECT MIN(s.rowid) FROM stop s WHERE s.trail_uid=t.uid)
                 JOIN stop l ON l.uid=t.current_stop ORDER BY t.position DESC,t.rowid DESC LIMIT ?1",
            )?;
            stmt.query_map([limit], |r| Ok(TrailSummary {
                uid: TrailUid(parse(&r.get::<_, String>(0)?)?), name: r.get(1)?, root_query: r.get(2)?,
                created_at: r.get(3)?, kept: r.get(4)?, root: entity(r, 5, 6)?, leaf: entity(r, 7, 8)?,
                stops: r.get(9)?, branches: r.get(10)?, played: r.get(11)?, wanted: r.get(12)?,
            }))?.collect()
        })
    }
}

fn load_stops(c: &Connection, trail: &str) -> rusqlite::Result<Vec<Stop>> {
    let mut stmt = c.prepare("SELECT uid,parent_uid,entity_kind,entity_id,via_kind,via_source,opened_at,dwell_ms,pruned FROM stop WHERE trail_uid=?1 ORDER BY rowid")?;
    let mut rows = stmt.query([trail])?;
    let mut indices = HashMap::new();
    let mut stops = Vec::new();
    let mut actions = c.prepare("SELECT action FROM stop_action WHERE stop_uid=?1 ORDER BY rowid")?;
    while let Some(row) = rows.next()? {
        let uid: String = row.get(0)?;
        let parent_uid: Option<String> = row.get(1)?;
        let parent = parent_uid.map(|p| indices.get(&p).copied().ok_or_else(|| invalid("stop parent does not precede child"))).transpose()?;
        let via_kind: Option<String> = row.get(4)?;
        let via = via_kind.map(|kind| Ok::<_, rusqlite::Error>(Via { kind: enum_value(&kind)?, source: row.get::<_, Option<String>>(5)?.unwrap_or_default() })).transpose()?;
        let stop_actions = actions.query_map([&uid], |r| enum_value(&r.get::<_, String>(0)?))?.collect::<rusqlite::Result<Vec<Action>>>()?;
        indices.insert(uid.clone(), stops.len());
        stops.push(Stop { uid: StopUid(parse(&uid)?), parent, entity: entity(row, 2, 3)?, via,
            opened_at: row.get(6)?, dwell_ms: row.get(7)?, actions: stop_actions, pruned: row.get(8)? });
    }
    Ok(stops)
}

fn entity_id(entity: EntityRef) -> String {
    match entity {
        EntityRef::Work(id) => id.0.to_string(), EntityRef::Recording(id) => id.0.to_string(),
        EntityRef::Release(id) => id.0.to_string(), EntityRef::Edition(id) => id.0.to_string(),
        EntityRef::Track(id) => id.0.to_string(), EntityRef::Agent(id) => id.0.to_string(),
        EntityRef::Context(id) => id.0.to_string(), EntityRef::Feed(id) => id.0.to_string(),
        EntityRef::Episode(id) => id.0.to_string(), EntityRef::Crate(id) => id.to_string(),
        EntityRef::Trail(id) => id.to_string(), EntityRef::Search => String::new(),
        EntityRef::Game(id) => id.0.to_string(),
    }
}

fn entity(row: &Row<'_>, kind: usize, id: usize) -> rusqlite::Result<EntityRef> {
    let value: String = row.get(id)?;
    Ok(match row.get::<_, i64>(kind)? {
        1 => EntityRef::Work(WorkId(parse(&value)?)), 2 => EntityRef::Recording(RecordingId(parse(&value)?)),
        3 => EntityRef::Release(ReleaseId(parse(&value)?)), 4 => EntityRef::Edition(EditionId(parse(&value)?)),
        5 => EntityRef::Track(TrackId(parse(&value)?)), 6 => EntityRef::Agent(AgentId(parse(&value)?)),
        7 => EntityRef::Context(ContextId(parse(&value)?)), 8 => EntityRef::Feed(FeedId(parse(&value)?)),
        9 => EntityRef::Episode(EpisodeId(parse(&value)?)), 10 => EntityRef::Crate(CrateUid(parse(&value)?)),
        11 => EntityRef::Trail(TrailUid(parse(&value)?)), 12 => EntityRef::Search,
        13 => EntityRef::Game(GameId(parse(&value)?)),
        _ => return Err(invalid("unknown trail entity kind")),
    })
}

fn parse<T: std::str::FromStr>(value: &str) -> rusqlite::Result<T> where T::Err: std::error::Error + Send + Sync + 'static {
    value.parse().map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))
}

fn invalid(message: &str) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(std::io::Error::new(std::io::ErrorKind::InvalidData, message)))
}

fn enum_name(value: &impl Serialize) -> String {
    serde_json::to_value(value).expect("trail enum serializes").as_str().expect("trail enum is a string").to_owned()
}

fn enum_value<T: DeserializeOwned>(value: &str) -> rusqlite::Result<T> {
    serde_json::from_value(serde_json::Value::String(value.into()))
        .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fork_pruning_actions_and_history_order_survive_reopen() {
        let dir = std::env::temp_dir().join(format!("meret-trails-{}", TrailUid::new()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("library.db");
        let store = Store::open(&path).unwrap();
        let mut trail = Trail::start(EntityRef::Search, Some("test query".into()), 1);
        let via = Via { kind: ThreadKind::Matched, source: "library".into() };
        let first = trail.follow(0, EntityRef::Release(ReleaseId(1)), via.clone(), 10_000);
        trail.act(first, Action::Played);
        trail.act(first, Action::Wanted);
        let discarded = trail.follow(0, EntityRef::Agent(AgentId(2)), via.clone(), 20_000);
        trail.go(first, 30_000);
        let branch = trail.branches(40_000).into_iter().find(|b| b.leaf == discarded).unwrap();
        trail.prune(&branch).unwrap();
        let fork = trail.follow(0, EntityRef::Agent(AgentId(3)), via, 40_000);
        trail.act(fork, Action::Noted);
        trail.kept = true;
        trail.name = Some("Saved fork".into());
        store.save_trail(&trail, 1, first).unwrap();
        store.save_trail(&trail, 1, first).unwrap();
        let newer = Trail::start(EntityRef::Search, Some("other".into()), 50_000);
        store.save_trail(&newer, 0, 0).unwrap(); // History order, not creation time.
        drop(store);
        let store = Store::open(&path).unwrap();
        let entries = store.load_trails().unwrap();
        assert_eq!(entries.len(), 2);
        let (restored, departure) = &entries[1];
        assert_eq!(*departure, first);
        assert_eq!(restored.current(), fork);
        assert_eq!(restored.name, trail.name);
        assert!(restored.kept);
        assert_eq!(serde_json::to_value(restored.stops()).unwrap(), serde_json::to_value(trail.stops()).unwrap());
        let summaries = store.trail_summaries(1).unwrap();
        assert_eq!(summaries[0].uid, trail.uid);
        assert_eq!((summaries[0].stops, summaries[0].branches, summaries[0].played, summaries[0].wanted), (3, 2, 1, 1));
        assert_eq!(store.read(|c| c.query_row("SELECT COUNT(*) FROM stop_action", [], |r| r.get::<_, i64>(0))).unwrap(), 3);
        let device = store.device_id().unwrap();
        assert_eq!(store.read(|c| c.query_row("SELECT COUNT(*) FROM stop WHERE device != ?1", [&device], |r| r.get::<_, i64>(0))).unwrap(), 0);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
