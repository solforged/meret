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

/// Now's Up next: the queue after the playing item. Ask again when Now's
/// item changes; the queue only moves with it.
pub fn up_next(limit: u32) -> Result<UpNextDto, String> {
    api()?.up_next(limit)
}

/// Adds a music folder and scans it in the background; returns the root id.
pub fn add_root(path: String) -> Result<i64, String> {
    api()?.add_root(&path)
}

/// Removes the folder from the library, keeping its files and stored history.
pub fn remove_root(id: i64) -> Result<(), String> {
    api()?.remove_root(id)
}

#[frb(sync)]
pub fn settings() -> Result<SettingsDto, String> {
    Ok(api()?.settings())
}

/// Persists settings. Output changes wait for the next track while playing;
/// when paused they apply on resume, and when idle on the next play.
pub fn set_settings(s: SettingsDto) -> Result<(), String> {
    api()?.set_settings(s)
}

pub fn output_devices() -> Result<Vec<OutputDeviceDto>, String> {
    api()?.output_devices()
}

pub fn volume() -> Result<VolumeDto, String> {
    api()?.volume()
}

pub fn set_volume(scalar: f32) -> Result<VolumeDto, String> {
    api()?.set_volume(scalar)
}

/// Budgeted discovery runs off the UI thread; protected folders aren't walked.
pub fn suggest_folders() -> Result<Vec<FolderSuggestionDto>, String> {
    Ok(api()?.suggest_folders())
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
pub fn rows(query: String, view: ViewDto, offset: u64, limit: u32) -> Result<RowsDto, String> {
    api()?.rows(&query, view, offset, limit)
}

/// Plays from a track ordinal in this view, replacing the queue.
pub fn play_results(query: String, view: ViewDto, index: u64) -> Result<(), String> {
    api()?.play_results(&query, view, index)
}

/// The cascaded idiom, person and release column browser.
pub fn facets(query: String) -> Result<FacetsDto, String> {
    api()?.facets(&query)
}

/// The query line's hits as you type a search: people, releases and tracks.
/// Errors when the input isn't a search.
pub fn search(input: String) -> Result<SearchDto, String> {
    api()?.search(&input)
}

/// A release pane: the tracklist, its formats and credits.
pub fn release(id: i64) -> Result<ReleaseDto, String> {
    api()?.release(id)
}

/// A person pane: their releases, what they're on, who they worked with.
pub fn person(id: i64) -> Result<PersonDto, String> {
    api()?.person(id)
}

/// Plays a release's tracklist from row `index`, replacing the queue.
/// `from_stop` is the pane it was played from; that stop is marked played.
pub fn play_release(id: i64, index: u32, from_stop: Option<u32>) -> Result<(), String> {
    api()?.play_release(id, index, from_stop)
}

/// Ends the current trail and roots a new one at `to`.
pub fn start_trail(to: TargetDto) -> Result<TrailDto, String> {
    Ok(api()?.start_trail(to))
}

/// Follows a thread from stop `from_stop`, the pane it was picked in; from
/// a pane before the last, this starts a branch.
pub fn follow(from_stop: u32, to: TargetDto, via: ThreadKind) -> Result<TrailDto, String> {
    api()?.follow(from_stop, to, via)
}

/// `[`: one stop back. None at the root.
pub fn trail_back() -> Result<Option<TrailDto>, String> {
    Ok(api()?.trail_back())
}

/// `]`: forward to the newest stop opened from this one. None when there's none.
pub fn trail_forward() -> Result<Option<TrailDto>, String> {
    Ok(api()?.trail_forward())
}

/// A star on the strip, clicked: that stop becomes current.
pub fn trail_go(stop: u32) -> Result<TrailDto, String> {
    api()?.trail_go(stop)
}

pub fn trail() -> Result<Option<TrailDto>, String> {
    Ok(api()?.trail())
}

pub fn trail_history(limit: u32) -> Result<Vec<TrailSummaryDto>, String> {
    api()?.trail_history(limit)
}

pub fn keep_trail(name: Option<String>) -> Result<TrailDto, String> {
    api()?.keep_trail(name)
}

/// A trail picked on the Front becomes active at the stop it was left on.
pub fn open_trail(uid: String) -> Result<TrailDto, String> {
    api()?.open_trail(&uid)
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

/// Every listen, including skips, newest first.
pub fn history(limit: u32) -> Result<Vec<ListenDto>, String> {
    api()?.history(limit)
}

pub fn most_played(days: u32, limit: u32) -> Result<Vec<PlayedDto>, String> {
    api()?.most_played(days, limit)
}

pub fn dormant(limit: u32) -> Result<Vec<DormantDto>, String> {
    api()?.dormant(limit)
}

/// Play something's picks, best first, each saying why.
pub fn picks(limit: u32) -> Result<Vec<PickDto>, String> {
    api()?.picks(limit)
}

/// `⇧Space`: plays the first pick and returns it; `None` when nothing is playable.
pub fn play_something() -> Result<Option<PickDto>, String> {
    api()?.play_something()
}

/// Play on: every zone and what it does to the sound.
pub fn zones() -> Result<Vec<ZoneDto>, String> {
    api()?.zones()
}

/// Sends output to a zone; while playing it applies from the next track.
pub fn play_on(zone: String) -> Result<(), String> {
    api()?.play_on(zone)
}

pub fn resume_points(limit: u32) -> Result<Vec<ResumeDto>, String> {
    api()?.resume_points(limit)
}

pub fn pick_up(release_id: i64) -> Result<(), String> {
    api()?.pick_up(release_id)
}
