//! `meret`: drive the core from a terminal.
//!
//! ```text
//! meret scan ~/Music                 walk a root and read tags, with timings
//! meret query 'idiom:score plays:0'  parse a query and print what it means
//! meret decode file.flac             decode a file: format, speed, DR, body
//! meret devices                     list output devices
//! meret play file.flac               play through the engine to the default device
//! meret play file.flac --null --speed 20   …or to nowhere, faster than real time
//!
//! meret library add ~/Music          add a root to the library and scan it into the store
//! meret library ls 'year:1990s'      page through a query, as the table does
//! meret library ls '' --group --sort year --desc   newest releases first
//! meret library facets 'idiom:score'  browse the idiom → person → release columns
//! meret library front                print the Front: the library by idiom and format, what's new, what needs you
//! meret library search 'iona'        the query line's hits, timing each prefix as if typed
//! meret library walk 'xenogears' 1 0  open hit 1, then that pane's thread 0, printing each pane and the trail
//! meret library play 'year:1998' --from 3 --tail 8   play results, timing every join
//! ```

mod library;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand, ValueEnum};
use meret_core::OutputChoice;
use meret_engine::engine::EngineConfig;
use meret_engine::output::OutputBackend;
use meret_engine::output::null::NullBackend;
use meret_engine::{Control, Engine, EngineEvent, Load, decode};
use rayon::prelude::*;

#[derive(Parser)]
#[command(name = "meret", about = "Drive Meret's core without a UI")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Walk a root and read tags for every audio file.
    Scan {
        root: PathBuf,
        /// Only walk; don't open files.
        #[arg(long)]
        stat_only: bool,
    },
    /// Parse a query-line input.
    Query { input: String },
    /// Decode a file end to end and report on it.
    Decode { file: PathBuf },
    /// List output devices.
    Devices,
    /// Play a file through the engine.
    Play {
        file: PathBuf,
        /// Output device, by name or UID. Default: the system's.
        #[arg(long)]
        device: Option<String>,
        /// Share the device instead of taking it (no hog mode).
        #[arg(long)]
        shared: bool,
        /// Play to nowhere instead of a device.
        #[arg(long)]
        null: bool,
        /// With --null: how much faster than real time.
        #[arg(long, default_value_t = 1.0)]
        speed: f64,
    },
    /// The library, through the same API the app uses.
    Library {
        /// The data directory. Default: the app's, so both see one library.
        #[arg(long, global = true)]
        data: Option<PathBuf>,
        #[command(subcommand)]
        cmd: LibraryCmd,
    },
}

#[derive(Subcommand)]
enum LibraryCmd {
    /// Add a folder as a root and scan it into the store.
    Add { root: PathBuf },
    /// Remove a root, keeping its files and stored history.
    Rm { id: i64 },
    /// Suggest music folders without prompting for access.
    Suggest,
    /// Rescan every root.
    Rescan,
    /// Print the Front, as the app's first pane shows it.
    Front,
    /// Print the query line's hits for a search, timing every prefix of it
    /// as if it were typed.
    Search { input: String },
    /// Search, then open one numbered line per step: a hit from the search,
    /// then a thread from each pane. Prints every pane and the trail.
    Walk { search: String, steps: Vec<usize> },
    /// Print a page of a query's rows ('' for everything).
    Ls {
        #[arg(default_value = "")]
        query: String,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 50)]
        limit: u32,
        #[arg(long, value_enum, default_value = "library")]
        sort: Sort,
        #[arg(long)]
        desc: bool,
        #[arg(long)]
        group: bool,
    },
    /// Print the idiom, person and release column browser.
    Facets {
        #[arg(default_value = "")]
        query: String,
    },
    /// Play a query's rows through the queue and time every join.
    Play {
        #[arg(default_value = "")]
        query: String,
        /// The row to start at.
        #[arg(long, default_value_t = 0)]
        from: u64,
        /// Stop after this many items have ended.
        #[arg(long)]
        count: Option<usize>,
        /// Seek into each item's last N seconds, to hear the joins sooner.
        #[arg(long)]
        tail: Option<f64>,
        #[command(flatten)]
        out: OutputArgs,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Sort {
    Library,
    Title,
    Artist,
    Album,
    Year,
    Length,
    Format,
}

impl From<Sort> for meret_api::SortKeyDto {
    fn from(sort: Sort) -> Self {
        match sort {
            Sort::Library => Self::Library,
            Sort::Title => Self::Title,
            Sort::Artist => Self::Artist,
            Sort::Album => Self::Album,
            Sort::Year => Self::Year,
            Sort::Length => Self::Length,
            Sort::Format => Self::Format,
        }
    }
}

#[derive(Args)]
struct OutputArgs {
    /// Output device, by name or UID. Default: the system's.
    #[arg(long)]
    device: Option<String>,
    /// Share the device instead of taking it (no hog mode).
    #[arg(long)]
    shared: bool,
    /// Play to nowhere instead of a device.
    #[arg(long)]
    null: bool,
    /// With --null: how much faster than real time.
    #[arg(long, default_value_t = 1.0)]
    speed: f64,
}

impl OutputArgs {
    fn choice(&self) -> OutputChoice {
        if self.null {
            OutputChoice::Null { speed: self.speed }
        } else {
            OutputChoice::System { device: self.device.clone(), exclusive: !self.shared }
        }
    }
}

fn main() -> Result<()> {
    tracing_subscriber::fmt().with_env_filter(tracing_subscriber::EnvFilter::from_default_env()).init();
    match Cli::parse().cmd {
        Cmd::Scan { root, stat_only } => scan(root, stat_only),
        Cmd::Query { input } => query(&input),
        Cmd::Decode { file } => decode_file(file),
        Cmd::Devices => devices(),
        Cmd::Play { file, device, shared, null, speed } => {
            let backend = if null { Arc::new(NullBackend { speed }) as Arc<dyn OutputBackend> } else { system_backend() };
            let config = EngineConfig { device, exclusive: !shared, ..Default::default() };
            play(file, backend, config)
        }
        Cmd::Library { data, cmd } => {
            let data = data.unwrap_or_else(library::default_data_dir);
            let output = match &cmd {
                LibraryCmd::Play { out, .. } => out.choice(),
                _ => OutputChoice::Null { speed: 1.0 },
            };
            let (api, rt) = library::open(&data, output)?;
            match cmd {
                LibraryCmd::Add { root } => library::add(&api, &rt, &root),
                LibraryCmd::Rm { id } => library::remove(&api, id),
                LibraryCmd::Suggest => library::suggest(&api),
                LibraryCmd::Rescan => library::rescan(&api, &rt),
                LibraryCmd::Front => library::front(&api, &rt),
                LibraryCmd::Search { input } => library::search(&api, &rt, &input),
                LibraryCmd::Walk { search, steps } => library::walk(&api, &rt, &search, &steps),
                LibraryCmd::Ls { query, offset, limit, sort, desc, group } => {
                    library::ls(&api, &rt, &query, meret_api::ViewDto { sort: sort.into(), descending: desc, group }, offset, limit)
                }
                LibraryCmd::Facets { query } => library::facets(&api, &rt, &query),
                LibraryCmd::Play { query, from, count, tail, .. } => {
                    library::play(&api, &rt, &query, library::PlayOptions { from, count, tail })
                }
            }
        }
    }
}

fn scan(root: PathBuf, stat_only: bool) -> Result<()> {
    let t = Instant::now();
    let files = meret_library::walk(&root);
    let walked = t.elapsed();
    let bytes: u64 = files.iter().map(|f| f.size).sum();
    println!("walked {} audio files ({:.1} GB) in {walked:.2?}", files.len(), bytes as f64 / 1e9);
    if stat_only {
        return Ok(());
    }

    let t = Instant::now();
    let tags: Vec<_> = files.par_iter().map(|f| meret_library::read_tags(&root.join(&f.rel_path))).collect();
    let read = t.elapsed();
    let ok = tags.iter().filter(|t| t.is_ok()).count();
    println!("read tags for {ok} of {} in {read:.2?} ({:.0} files/s)", files.len(), ok as f64 / read.as_secs_f64());

    let mut by_type = std::collections::BTreeMap::<String, (usize, usize)>::new();
    let (mut mbid, mut isrc) = (0, 0);
    for t in tags.iter().flatten() {
        let e = by_type.entry(t.file_type.clone()).or_default();
        e.0 += 1;
        if t.bits.unwrap_or(16) > 16 || t.sample_rate.unwrap_or(44_100) > 48_000 {
            e.1 += 1;
        }
        mbid += t.mb_recording.is_some() as usize;
        isrc += t.isrc.is_some() as usize;
    }
    for (ty, (n, hires)) in by_type {
        println!("  {ty:<10} {n:>8}   hi-res {hires}");
    }
    println!("  with a MusicBrainz recording ID: {mbid}; with an ISRC: {isrc}");
    for e in tags.iter().filter_map(|t| t.as_ref().err()).take(5) {
        println!("  ! {e}");
    }
    Ok(())
}

fn query(input: &str) -> Result<()> {
    match meret_query::parse(input) {
        Ok(parsed) => {
            if let meret_query::Input::Search(q) = &parsed {
                println!("canonical: {q}");
            }
            println!("{}", serde_json::to_string_pretty(&parsed)?);
        }
        Err(e) => println!("error: {e}"),
    }
    Ok(())
}

fn decode_file(file: PathBuf) -> Result<()> {
    let mut d = decode::open(&file).with_context(|| format!("opening {}", file.display()))?;
    let spec = d.spec();
    let t = Instant::now();
    let mut samples = Vec::new();
    while d.read(&mut samples)? > 0 {}
    let took = t.elapsed();
    let frames = samples.len() / spec.channels as usize;
    let secs = frames as f64 / spec.sample_rate as f64;
    println!("{}", spec.describe());
    println!("{frames} frames, {secs:.2} s, decoded in {took:.2?} ({:.0}× real time)", secs / took.as_secs_f64());
    if let Some(total) = d.total_frames()
        && total != frames as u64
    {
        println!("note: container said {total} frames");
    }
    let f = meret_analysis::to_f32(&samples);
    if let Some(dr) = meret_analysis::dynamic_range(&f, spec.channels as usize, spec.sample_rate) {
        println!("DR{dr}");
    }
    let body = meret_analysis::BodySummary::from_samples(&f, spec.channels as usize, spec.sample_rate, 48);
    let bars = " ▁▂▃▄▅▆▇█";
    let line: String =
        body.loudness.iter().map(|&b| bars.chars().nth(b as usize * 8 / 255).unwrap_or(' ')).collect();
    println!("body {line}");
    Ok(())
}

fn system_backend() -> Arc<dyn OutputBackend> {
    #[cfg(target_os = "macos")]
    return Arc::new(meret_engine::output::coreaudio::CoreAudioBackend);
    #[cfg(not(target_os = "macos"))]
    return Arc::new(NullBackend { speed: 1.0 });
}

fn devices() -> Result<()> {
    for d in system_backend().devices()? {
        let rates: Vec<String> = d.sample_rates.iter().map(|r| format!("{}", *r as f64 / 1000.0)).collect();
        let hog = if d.can_be_exclusive { "exclusive" } else { "shared only" };
        println!("{}  ·  {} kHz  ·  {} bit  ·  {hog}\n    {}", d.name, rates.join("/"), d.max_bits, d.id);
    }
    Ok(())
}

fn play(file: PathBuf, backend: Arc<dyn OutputBackend>, config: EngineConfig) -> Result<()> {
    let decoder = decode::open(&file)?;
    let engine = Engine::spawn(backend, config);
    engine.send(Control::Play(Load { item: 1, decoder, start_frame: 0, stages: vec![] }));
    let t = Instant::now();
    let mut anchors = 0;
    while let Ok(e) = engine.events().recv_timeout(Duration::from_secs(30)) {
        match e {
            EngineEvent::Started { path, .. } => {
                let stages: Vec<String> = path.stages.iter().map(|s| format!("{} [{}]", s.name, s.detail)).collect();
                println!("started: {} → {:?}", stages.join(" → "), path.fidelity());
            }
            EngineEvent::Anchor(_) => anchors += 1,
            EngineEvent::Ended { .. } => println!("ended after {:.2?} wall clock", t.elapsed()),
            EngineEvent::Idle => break,
            EngineEvent::Error { message, .. } => println!("error: {message}"),
        }
    }
    println!("{anchors} anchor updates sent (the UI extrapolates between them)");
    Ok(())
}
