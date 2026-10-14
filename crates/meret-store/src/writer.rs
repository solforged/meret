//! The single writer. Every write in the app goes through here.
//!
//! Work queued while a transaction is running is batched into the next one,
//! up to `MAX_BATCH`, so a scan that sends thousands of small writes costs a
//! handful of commits.

use std::thread;

use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
use rusqlite::{Connection, Transaction};

use crate::{Result, StoreError};

const MAX_BATCH: usize = 256;

type Job = Box<dyn FnOnce(&Transaction<'_>) + Send>;

#[derive(Clone)]
pub struct Writer {
    tx: Sender<Job>,
}

impl Writer {
    pub(crate) fn spawn(mut conn: Connection) -> Self {
        let (tx, rx) = unbounded::<Job>();
        thread::Builder::new()
            .name("meret-writer".into())
            .spawn(move || run(&mut conn, rx))
            .expect("spawn writer thread");
        Self { tx }
    }

    /// Queues a write and blocks until it has committed.
    /// From async code, call this inside `spawn_blocking`, or use `write_detached`.
    pub fn write<T: Send + 'static>(
        &self,
        f: impl FnOnce(&Transaction<'_>) -> rusqlite::Result<T> + Send + 'static,
    ) -> Result<T> {
        let (done_tx, done_rx) = bounded(1);
        self.tx
            .send(Box::new(move |tx| {
                let _ = done_tx.send(f(tx));
            }))
            .map_err(|_| StoreError::WriterGone)?;
        Ok(done_rx.recv().map_err(|_| StoreError::WriterGone)??)
    }

    /// Queues a write and returns at once. Errors are logged.
    pub fn write_detached(&self, f: impl FnOnce(&Transaction<'_>) -> rusqlite::Result<()> + Send + 'static) {
        let _ = self.tx.send(Box::new(move |tx| {
            if let Err(e) = f(tx) {
                tracing::error!(error = %e, "detached write failed");
            }
        }));
    }
}

fn run(conn: &mut Connection, rx: Receiver<Job>) {
    while let Ok(first) = rx.recv() {
        let tx = match conn.transaction() {
            Ok(tx) => tx,
            Err(e) => {
                tracing::error!(error = %e, "could not begin a write transaction");
                continue;
            }
        };
        first(&tx);
        for job in rx.try_iter().take(MAX_BATCH - 1) {
            job(&tx);
        }
        if let Err(e) = tx.commit() {
            tracing::error!(error = %e, "write batch failed to commit");
        }
        // TODO(core): after commit, publish the tables and ids touched so
        // meret-core can invalidate live queries.
    }
}
