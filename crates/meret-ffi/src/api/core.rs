use std::path::PathBuf;
use std::sync::OnceLock;

use flutter_rust_bridge::frb;
use meret_api::Api;
use meret_core::{CoreConfig, OutputChoice};

use super::types::*;
use crate::frb_generated::StreamSink;

static API: OnceLock<Api> = OnceLock::new();

fn api() -> Result<&'static Api, String> {
    API.get().ok_or_else(|| "the core isn't started; call start_core first".to_string())
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Starts the process-wide core, or attaches to the running one. On macOS
/// the app delegate may already have started it for the menu bar.
pub fn start_core(data_dir: String, null_output: bool) -> Result<(), String> {
    let output = if null_output {
        OutputChoice::Null { speed: 1.0 }
    } else {
        OutputChoice::System { device: None, exclusive: true }
    };
    let core = meret_core::start(CoreConfig {
        data_dir: PathBuf::from(data_dir),
        output,
        contact: "meret@localhost".into(),
    })
    .map_err(|e| e.to_string())?;
    let _ = API.set(Api::new(core));
    Ok(())
}

#[frb(sync)]
pub fn parse_query(input: String) -> Result<QueryDto, String> {
    Ok(api()?.parse_query(&input))
}

pub fn histogram(column: ColumnDto, query: String, lo: f64, hi: f64, bins: u32) -> Result<HistogramDto, String> {
    Ok(api()?.histogram(column, &query, lo, hi, bins))
}

pub fn transport(cmd: TransportDto) -> Result<(), String> {
    api()?.transport(cmd)
}

/// Adds a music folder and scans it in the background; returns the root id.
pub fn add_root(path: String) -> Result<i64, String> {
    api()?.add_root(&path)
}

/// Runs a query-line command: `play <query>` plays what matches; the
/// other commands return an error that says they aren't built yet.
pub fn run_command(input: String) -> Result<(), String> {
    api()?.run_command(&input)
}

/// The Front: the library by idiom and format, what arrived lately, what
/// needs you, and the folders. Ask again when `libraryVersion` moves.
pub fn front() -> Result<FrontDto, String> {
    api()?.front()
}

/// A page of the table for `query`. Call as rows scroll into view, never in
/// `build`.
pub fn rows(query: String, offset: u64, limit: u32) -> Result<RowsDto, String> {
    api()?.rows(&query, offset, limit)
}

/// Plays `query`'s result from row `index`, replacing the queue.
pub fn play_results(query: String, index: u64) -> Result<(), String> {
    api()?.play_results(&query, index)
}

pub fn trail() -> Result<Option<TrailDto>, String> {
    Ok(api()?.trail())
}

/// Now, pushed whenever it changes: a new item, a new anchor, a new path.
pub async fn watch_now(sink: StreamSink<NowDto>) -> Result<(), String> {
    let api = api()?;
    let mut rx = api.subscribe_now();
    let _ = sink.add(api.now());
    while let Some(now) = api.now_changed(&mut rx).await {
        if sink.add(now).is_err() {
            break;
        }
    }
    Ok(())
}

/// The status line, pushed whenever it changes.
pub async fn watch_status(sink: StreamSink<StatusDto>) -> Result<(), String> {
    let api = api()?;
    let mut rx = api.subscribe_status();
    let _ = sink.add(api.status());
    while rx.changed().await.is_ok() {
        let s = StatusDto::from(&*rx.borrow());
        if sink.add(s).is_err() {
            break;
        }
    }
    Ok(())
}
