use rusqlite::Connection;

/// Migrations in order. Append; never edit one that has shipped.
const MIGRATIONS: &[&str] = &[
    include_str!("../migrations/0001_init.sql"),
    include_str!("../migrations/0002_scan.sql"),
    include_str!("../migrations/0003_search.sql"),
    include_str!("../migrations/0004_art.sql"),
    include_str!("../migrations/0005_settings.sql"),
    include_str!("../migrations/0006_copies.sql"),
    include_str!("../migrations/0007_credits.sql"),
    include_str!("../migrations/0008_memory.sql"),
    include_str!("../migrations/0009_trails.sql"),
    include_str!("../migrations/0010_queue_listen.sql"),
    include_str!("../migrations/0011_fsevents_uuid.sql"),
];

pub fn run(conn: &mut Connection) -> rusqlite::Result<()> {
    let current: usize = conn.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))? as usize;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(current) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql)?;
        if i + 1 == 6 {
            crate::copies::merge_existing(&tx)?;
        }
        if i + 1 == 7 {
            crate::credits::migrate(&tx)?;
        }
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
        tracing::info!(version = i + 1, "migrated library.db");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copies_migration_preserves_ids_claims_history_and_references() {
        let mut c = Connection::open_in_memory().unwrap();
        c.pragma_update(None, "foreign_keys", true).unwrap();
        crate::search::register(&c).unwrap();
        for sql in MIGRATIONS.iter().take(5) {
            c.execute_batch(sql).unwrap();
        }
        c.pragma_update(None, "user_version", 5).unwrap();
        c.execute_batch(
            "INSERT INTO release(id,title,idiom,rev) VALUES(1,'Tyranny',6,1);
             INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
             INSERT INTO medium(id,edition_id,position) VALUES(1,1,1);
             INSERT INTO recording(id,title,length_ms,rev) VALUES(1,'1 - Térratus',10000,1),(2,'Terratus!',10020,1);
             INSERT INTO track(id,medium_id,position,recording_id,title,length_ms,rev)
                VALUES(1,1,1,1,'1 - Térratus',10000,1),(2,1,1,2,'Terratus!',10020,1);
             INSERT INTO root(id,label,path,kind) VALUES(1,'Music','/music','local');
             INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES(1,1,'a.mp3',1,1,1),(2,1,'a.flac',1,1,1);
             INSERT INTO source(id,recording_id,track_id,kind,file_id,codec,lossless,rev)
                VALUES(1,1,1,'file',1,'MP3',0,1),(2,2,2,'file',2,'FLAC',1,1);
             INSERT INTO agent(id,kind,name,rev) VALUES(1,0,'Composer',1);
             INSERT INTO credit(subject_kind,subject_id,agent_id,role,rev)
                VALUES(2,1,1,'artist',1),(2,2,1,'artist',1),(5,2,1,'composer',1);
             INSERT INTO listen(uid,recording_id,source_id,started_at,played_ms,device)
                VALUES('a',1,1,1,100,'test'),('b',2,2,2,100,'test');
             INSERT INTO note(uid,subject_kind,subject_id,body,created_at,updated_at,device) VALUES('n',2,2,'kept',1,1,'test');
             INSERT INTO context(id,title,rev) VALUES(1,'Scene',1);
             INSERT INTO recording_context VALUES(2,1,NULL);
             INSERT INTO artwork(hash) VALUES(X'AB');
             INSERT INTO entity_artwork VALUES(2,2,X'AB'),(5,2,X'AB');
             INSERT INTO analysis(recording_id,dr,analysed_at,version) VALUES(2,12,1,1);
             INSERT INTO external_id VALUES(2,2,'isrc','x');
             INSERT INTO edge(from_kind,from_id,to_kind,to_id,kind,rev) VALUES(2,2,5,2,'by',1);
             INSERT INTO resume VALUES(2,1,1,100,1,'test'),(2,2,2,200,2,'test');
             INSERT INTO trail(uid,created_at,device) VALUES('trail',1,'test');
             INSERT INTO stop(uid,trail_uid,entity_kind,entity_id,opened_at,device) VALUES('stop','trail',5,'2',1,'test');
             INSERT INTO crate(uid,name,kind,created_at,updated_at,device) VALUES('c','C','set',1,1,'test');
             INSERT INTO crate_item VALUES('c','1',2,'2',1);
             INSERT INTO want(uid,entity_kind,entity_id,created_at,device) VALUES('w',2,'2',1,'test');",
        ).unwrap();
        run(&mut c).unwrap();
        let count = |table: &str| c.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get::<_, i64>(0)).unwrap();
        assert_eq!((count("track"), count("recording"), count("source"), count("listen")), (1,1,2,2));
        assert_eq!(c.query_row("SELECT title FROM track WHERE id=1", [], |r| r.get::<_, String>(0)).unwrap(), "Térratus");
        assert_eq!(c.query_row("SELECT COUNT(*) FROM source WHERE track_id=1 AND recording_id=1", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
        assert_eq!(c.query_row("SELECT COUNT(*) FROM listen WHERE recording_id=1", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
        assert_eq!(count("credit"), 2, "identical recording claims are deduplicated, track claim remains");
        assert_eq!(c.query_row("SELECT subject_id FROM note", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        assert_eq!(c.query_row("SELECT recording_id FROM recording_context", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        assert_eq!(c.query_row("SELECT recording_id FROM analysis", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        assert_eq!(c.query_row("SELECT COUNT(*) FROM entity_artwork WHERE entity_id=1", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
        assert_eq!(c.query_row("SELECT entity_id FROM external_id", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        assert_eq!(c.query_row("SELECT from_id + to_id FROM edge", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
        assert_eq!(c.query_row("SELECT position_ms FROM resume WHERE subject_kind=2 AND subject_id=1", [], |r| r.get::<_, i64>(0)).unwrap(), 200);
        for table in ["stop", "crate_item", "want"] {
            assert_eq!(c.query_row(&format!("SELECT entity_id FROM {table}"), [], |r| r.get::<_, String>(0)).unwrap(), "1");
        }
        assert_eq!(c.query_row("SELECT COUNT(*) FROM search WHERE entity_kind=2", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
        assert_eq!(c.query_row("SELECT title FROM search WHERE entity_kind=2", [], |r| r.get::<_, String>(0)).unwrap(), "terratus");
        let version: i64 = c.pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
        run(&mut c).unwrap();
        assert_eq!(c.query_row("SELECT COUNT(*) FROM track", [], |r| r.get::<_, i64>(0)).unwrap(), 1);
    }

    #[test]
    fn credits_migrate_without_rescanning_and_keep_written_strings() {
        let mut conn = Connection::open_in_memory().unwrap();
        crate::search::register(&conn).unwrap();
        for sql in &MIGRATIONS[..5] { conn.execute_batch(sql).unwrap(); }
        conn.pragma_update(None, "user_version", 5).unwrap();
        conn.execute_batch(
            "INSERT INTO provenance (id, source, fetched_at) VALUES (1, 'local_tags', 0);
             INSERT INTO agent (id, kind, name, rev) VALUES
               (1, 0, 'Geoff Knorr', 1), (2, 0, 'Geoff Knorr & Michael Curran', 1),
               (3, 0, 'George Frideric Handel , Thomas Beecham', 1),
               (4, 0, 'George Frideric Handel, Thomas Beecham', 1),
               (5, 0, 'Gibbons, Orlando', 1), (6, 0, 'Jan Stoeckart [ 24 ]', 1),
               (7, 0, 'JAN  STOECKART', 1), (8, 0, 'Orphan', 1);
             INSERT INTO recording (id, title, rev) VALUES
               (1, 'One', 1), (2, 'Two', 1), (3, 'Three', 1), (4, 'Four', 1), (5, 'Five', 1);
             INSERT INTO release (id, title, rev) VALUES (1, 'Joint release', 1);
             INSERT INTO credit (subject_kind, subject_id, agent_id, role, provenance_id, rev) VALUES
               (2, 1, 1, 'artist', 1, 1), (2, 2, 2, 'artist', 1, 1), (3, 1, 2, 'album_artist', 1, 1),
               (2, 3, 3, 'artist', 1, 1), (2, 4, 4, 'artist', 1, 1), (2, 5, 5, 'artist', 1, 1),
               (2, 5, 6, 'artist', 1, 1), (2, 5, 7, 'artist', 1, 1);
             INSERT INTO search (rowid, entity_kind, entity_id, title, people, extra) VALUES (134, 6, 8, 'orphan', '', '');"
        ).unwrap();
        run(&mut conn).unwrap();
        let names = conn.prepare("SELECT name FROM agent ORDER BY name").unwrap()
            .query_map([], |r| r.get::<_, String>(0)).unwrap().collect::<rusqlite::Result<Vec<_>>>().unwrap();
        assert_eq!(names, ["Geoff Knorr", "George Frideric Handel", "Gibbons, Orlando", "Jan Stoeckart", "Michael Curran", "Thomas Beecham"]);
        assert_eq!(conn.query_row("SELECT COUNT(*) FROM credit WHERE agent_id = 1 AND subject_kind = 2", [], |r| r.get::<_, u32>(0)).unwrap(), 2);
        assert_eq!(conn.query_row("SELECT artist_credit FROM recording WHERE id = 2", [], |r| r.get::<_, String>(0)).unwrap(), "Geoff Knorr & Michael Curran");
        assert_eq!(conn.query_row("SELECT album_artist_credit FROM release WHERE id = 1", [], |r| r.get::<_, String>(0)).unwrap(), "Geoff Knorr & Michael Curran");
        assert_eq!(conn.query_row("SELECT COUNT(*) FROM search WHERE entity_kind = 6", [], |r| r.get::<_, u32>(0)).unwrap(), 6);
        let credits: u32 = conn.query_row("SELECT COUNT(*) FROM credit", [], |r| r.get(0)).unwrap();
        run(&mut conn).unwrap();
        assert_eq!(conn.query_row("SELECT COUNT(*) FROM credit", [], |r| r.get::<_, u32>(0)).unwrap(), credits);
    }
}
