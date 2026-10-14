use rusqlite::Connection;

/// Migrations in order. Append; never edit one that has shipped.
const MIGRATIONS: &[&str] = &[include_str!("../migrations/0001_init.sql"), include_str!("../migrations/0002_scan.sql")];

pub fn run(conn: &mut Connection) -> rusqlite::Result<()> {
    let current: usize = conn.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))? as usize;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(current) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
        tracing::info!(version = i + 1, "migrated library.db");
    }
    Ok(())
}
