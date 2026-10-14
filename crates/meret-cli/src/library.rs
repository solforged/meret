//! `meret library …`: the library through `meret-api`, as the app sees it.
//! Scan a folder into the store, page through a query, and play results
//! through the queue, timing every join.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Result, anyhow};
use meret_api::{Api, StatusDto, TargetDto, ThreadDto, ThreadKind, TransportDto};
use meret_core::{CoreConfig, OutputChoice};
use meret_engine::{Anchor, EngineEvent, decode};
use tokio::sync::broadcast::error::RecvError;

/// The app's own data directory, so the CLI and the app share a library.
pub fn default_data_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/io.sowilo.meret")
    } else {
        home.join(".local/share/meret")
    }
}

pub fn open(data: &Path, output: OutputChoice) -> Result<(Api, tokio::runtime::Runtime)> {
    let core = meret_core::start(CoreConfig { data_dir: data.into(), output, contact: "meret@localhost".into() })?;
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().build()?;
    Ok((Api::new(core), rt))
}

/// Waits for queued scans, printing their progress as the status line would.
fn settle(api: &Api, rt: &tokio::runtime::Runtime) {
    let mut status = api.subscribe_status();
    let mut settled = api.scans_settled();
    rt.block_on(async {
        let mut last = String::new();
        loop {
            tokio::select! {
                _ = &mut settled => break,
                Ok(()) = status.changed() => {
                    let line = progress_line(&StatusDto::from(&*status.borrow()));
                    if !line.is_empty() && line != last {
                        eprintln!("  {line}");
                        last = line;
                    }
                }
            }
        }
    });
}

fn progress_line(s: &StatusDto) -> String {
    s.jobs.iter().map(|j| format!("↻ {} {} of {}", j.verb, j.done, j.total)).collect::<Vec<_>>().join("  ")
}

pub fn add(api: &Api, rt: &tokio::runtime::Runtime, root: &Path) -> Result<()> {
    settle(api, rt);
    let before = api.status().tracks;
    let t = Instant::now();
    let id = api.add_root(&root.to_string_lossy()).map_err(|e| anyhow!(e))?;
    settle(api, rt);
    let after = api.status().tracks;
    println!(
        "root {id}: {} in {:.2?}; the table holds {after} tracks ({:+})",
        root.display(),
        t.elapsed(),
        after as i64 - before as i64
    );
    Ok(())
}

pub fn rescan(api: &Api, rt: &tokio::runtime::Runtime) -> Result<()> {
    settle(api, rt);
    let t = Instant::now();
    api.rescan();
    settle(api, rt);
    println!("rescanned in {:.2?}; the table holds {} tracks", t.elapsed(), api.status().tracks);
    Ok(())
}

pub fn ls(api: &Api, rt: &tokio::runtime::Runtime, query: &str, offset: u64, limit: u32) -> Result<()> {
    settle(api, rt);
    let t = Instant::now();
    let page = api.rows(query, offset, limit).map_err(|e| anyhow!(e))?;
    let took = t.elapsed();
    for (i, r) in page.rows.iter().enumerate() {
        let len = r.length_ms.map(|ms| format!("{}:{:02}", ms / 60_000, ms / 1000 % 60)).unwrap_or_default();
        println!(
            "{:>6}  {:>2}-{:<3} {:<40.40} {:<24.24} {:<32.32} {:>4} {:>6}  {}",
            offset as usize + i,
            r.disc,
            r.number,
            r.title,
            r.artist.as_deref().unwrap_or(""),
            r.album,
            r.year.map(|y| y.to_string()).unwrap_or_default(),
            len,
            r.format
        );
    }
    println!("{} of {} rows in {took:.2?}", page.rows.len(), page.total);
    Ok(())
}

pub fn front(api: &Api, rt: &tokio::runtime::Runtime) -> Result<()> {
    settle(api, rt);
    let t = Instant::now();
    let f = api.front().map_err(|e| anyhow!(e))?;
    let took = t.elapsed();
    let query = |q: &Option<String>| q.as_deref().map(|q| format!("  → {q}")).unwrap_or_default();
    println!("Collection · {} tracks · {} releases", f.tracks, f.releases);
    for l in &f.idioms {
        println!("  {:<16} {:>6} releases {:>7} tracks{}", l.label, l.releases, l.tracks, query(&l.query));
    }
    println!("By format");
    for l in &f.formats {
        println!("  {:<24} {:>7}  {:<24}{}", l.label, l.count, l.note, query(&l.query));
    }
    println!("Added lately");
    for r in &f.added_lately {
        let year = r.year.map(|y| y.to_string()).unwrap_or_default();
        println!("  {:<40.40} {:<24.24} {:>4} {:>3} tracks  → {}", r.title, r.artist.as_deref().unwrap_or(""), year, r.tracks, r.query);
    }
    println!("Needs you");
    for l in &f.needs_you {
        println!("  {:<32} {:>6}  {}", l.label, l.count, l.note);
    }
    println!("Folders");
    for r in &f.roots {
        println!("  {} {}", if r.online { "●" } else { "○" }, r.path);
    }
    println!("in {took:.2?}");
    Ok(())
}

pub fn search(api: &Api, rt: &tokio::runtime::Runtime, input: &str) -> Result<()> {
    settle(api, rt);
    // As typed: every prefix, the way the query line asks.
    let ends: Vec<usize> = input.char_indices().map(|(i, c)| i + c.len_utf8()).collect();
    let mut last = None;
    for end in ends {
        let typed = &input[..end];
        let t = Instant::now();
        let found = api.search(typed);
        let took = t.elapsed();
        match &found {
            Ok(s) => println!(
                "{typed:<24} {took:>10.2?}  {} people, {} releases, {} tracks",
                s.people_total, s.releases_total, s.tracks
            ),
            Err(e) => println!("{typed:<24} {took:>10.2?}  {e}"),
        }
        last = Some(found);
    }
    let s = last.ok_or_else(|| anyhow!("nothing to search"))?.map_err(|e| anyhow!(e))?;
    for (label, total, hits) in [
        ("People", s.people_total, &s.people),
        ("Releases", s.releases_total, &s.releases),
        ("Tracks", s.track_hits_total, &s.track_hits),
    ] {
        println!("{label} · {total}");
        for h in hits {
            let index = h.index.map(|i| format!(" @{i}")).unwrap_or_default();
            println!("  {:<40.40} {:<48.48} → {}{index}", h.title, h.detail, h.query);
        }
    }
    println!("All {} tracks → {}", s.tracks, s.query);
    Ok(())
}

/// Walks a trail the way the panes do: a search, then one numbered line
/// per step. Each pane is printed with its lines numbered for the next step.
pub fn walk(api: &Api, rt: &tokio::runtime::Runtime, search: &str, steps: &[usize]) -> Result<()> {
    settle(api, rt);
    let s = api.search(search).map_err(|e| anyhow!(e))?;
    let mut trail = api.start_trail(TargetDto::Search { query: s.query.clone() });
    println!("search {}: {} tracks", s.query, s.tracks);
    let mut lines: Vec<(ThreadKind, TargetDto, String)> = s
        .people
        .iter()
        .map(|h| (ThreadKind::Matched, TargetDto::Person { id: h.id }, format!("{} · {}", h.title, h.detail)))
        .chain(s.releases.iter().map(|h| (ThreadKind::Matched, TargetDto::Release { id: h.id }, format!("{} · {}", h.title, h.detail))))
        .collect();
    print_lines(&lines);
    for &step in steps {
        let (via, to, _) = lines.get(step).cloned().ok_or_else(|| anyhow!("there's no line {step}"))?;
        let t = Instant::now();
        trail = api.follow(trail.current, to.clone(), via).map_err(|e| anyhow!(e))?;
        lines = match to {
            TargetDto::Release { id } => {
                let r = api.release(id).map_err(|e| anyhow!(e))?;
                println!(
                    "\n{} · {} · {}  ({:.2?})",
                    r.title,
                    r.artist.as_deref().unwrap_or("no album artist"),
                    [r.idiom.clone(), r.year.map(|y| y.to_string()), Some(format!("{} tracks", r.tracks)), Some(r.formats.join(", "))]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>()
                        .join(" · "),
                    t.elapsed()
                );
                for row in &r.rows {
                    let artist = row.artist.as_deref().filter(|a| Some(*a) != r.artist.as_deref()).unwrap_or("");
                    println!("    {}-{:02} {:<44.44} {artist}", row.disc, row.number, row.title);
                }
                r.credits.iter().map(|c| (c.kind, c.to.clone(), thread_line(&c.label, c))).collect()
            }
            TargetDto::Person { id } => {
                let p = api.person(id).map_err(|e| anyhow!(e))?;
                println!("\n{} · {} tracks  ({:.2?})", p.name, p.tracks, t.elapsed());
                [("releases", &p.releases), ("on", &p.appears_on), ("worked with", &p.worked_with)]
                    .into_iter()
                    .flat_map(|(group, list)| {
                        list.iter().map(move |c| (c.kind, c.to.clone(), thread_line(group, c)))
                    })
                    .collect()
            }
            TargetDto::Search { .. } => unreachable!("a search is only a root"),
        };
        print_lines(&lines);
    }
    let strip: Vec<String> = trail
        .stops
        .iter()
        .filter(|s| s.on_path)
        .map(|s| match &s.via {
            Some(via) => format!("—{via}→ {}", s.title),
            None => s.title.clone(),
        })
        .collect();
    println!("\ntrail: {}", strip.join(" "));
    Ok(())
}

fn thread_line(label: &str, c: &ThreadDto) -> String {
    [c.title.as_str(), c.detail.as_str(), c.source.as_str()].into_iter().filter(|s| !s.is_empty()).fold(label.to_string(), |acc, s| {
        if acc == label { format!("{acc} {s}") } else { format!("{acc} · {s}") }
    })
}

fn print_lines(lines: &[(ThreadKind, TargetDto, String)]) {
    for (i, (_, _, text)) in lines.iter().enumerate() {
        println!("  [{i}] {text}");
    }
}

pub struct PlayOptions {
    pub from: u64,
    /// Stop once this many items have ended.
    pub count: Option<usize>,
    /// Seek each item to its last this-many seconds, to hear joins quickly.
    pub tail: Option<f64>,
}

/// One item as the device played it: its first and last anchors, and how
/// many frames its file holds.
#[derive(Default)]
struct Heard {
    first: Option<Anchor>,
    last: Option<Anchor>,
    frames: Option<u64>,
    seeked: bool,
}

/// Plays `query`'s result through the queue and checks every join: the
/// events must come as Ended n, Started n+1, and the device must have
/// started n+1 the moment n's last frame played.
pub fn play(api: &Api, rt: &tokio::runtime::Runtime, query: &str, opts: PlayOptions) -> Result<()> {
    settle(api, rt);
    let mut events = api.subscribe_events();
    api.play_results(query, opts.from).map_err(|e| anyhow!(e))?;
    let uris: HashMap<u64, String> = api.queue().into_iter().collect();
    println!("queued {} items", uris.len());

    let t = Instant::now();
    let mut order: Vec<String> = vec![];
    let mut heard: HashMap<u64, Heard> = HashMap::new();
    let mut started: Vec<u64> = vec![];
    let mut ended = 0usize;
    rt.block_on(async {
        loop {
            // Anchors are only sent on a change, so a long track can be
            // silent for its whole length; wait for Idle.
            let e = match events.recv().await {
                Ok(e) => e,
                Err(RecvError::Lagged(n)) => {
                    println!("! missed {n} events");
                    continue;
                }
                Err(RecvError::Closed) => break,
            };
            match e {
                EngineEvent::Started { item, path } => {
                    order.push(format!("start {item}"));
                    started.push(item);
                    let now = api.now();
                    let out = path.stages.last().map(|s| s.detail.clone()).unwrap_or_default();
                    println!(
                        "{:>8.2?}  ▶ {item:<4} {} · {}  [{} → {out}] {:?}",
                        t.elapsed(),
                        now.title,
                        now.subtitle,
                        path.stages.first().map(|s| s.detail.as_str()).unwrap_or(""),
                        path.fidelity()
                    );
                    let frames = uris
                        .get(&item)
                        .and_then(|u| u.strip_prefix("file://"))
                        .and_then(|p| decode::open(Path::new(p)).ok())
                        .and_then(|d| d.total_frames());
                    heard.entry(item).or_default().frames = frames;
                }
                EngineEvent::Anchor(a) if a.rate > 0.0 => {
                    let h = heard.entry(a.item).or_default();
                    if h.first.is_none() {
                        h.first = Some(a);
                        if let (Some(tail), Some(frames)) = (opts.tail, h.frames) {
                            let ms = (frames as f64 / a.sample_rate as f64 - tail).max(0.0) * 1000.0;
                            let _ = api.transport(TransportDto::Seek { ms: ms as u64 });
                            h.seeked = true;
                        }
                    }
                    h.last = Some(a);
                }
                EngineEvent::Anchor(_) => {}
                EngineEvent::Ended { item } => {
                    order.push(format!("end {item}"));
                    println!("{:>8.2?}  ■ {item}", t.elapsed());
                    ended += 1;
                    if opts.count.is_some_and(|c| ended >= c) {
                        let _ = api.transport(TransportDto::Stop);
                    }
                }
                EngineEvent::Idle => {
                    order.push("idle".into());
                    break;
                }
                EngineEvent::Error { item, message } => println!("! {item:?}: {message}"),
            }
        }
    });

    // Every join must be "end n" immediately followed by "start n+1".
    let joins_in_order = order
        .windows(2)
        .filter(|w| w[0].starts_with("end") && w[1].starts_with("start"))
        .count();
    println!("events: {}", order.join(", "));
    println!("{joins_in_order} joins reported as Ended then Started");

    // Where the device put each item's first frame, from its first anchor,
    // against where the previous item's last frame went, from its last.
    for pair in started.windows(2) {
        let (a, b) = (&heard[&pair[0]], &heard[&pair[1]]);
        let (Some(last), Some(frames), Some(first)) = (a.last, a.frames, b.first) else {
            println!("  {} → {}: not enough anchors to time", pair[0], pair[1]);
            continue;
        };
        let end_ns = last.at_ns as f64 + (frames as f64 - last.position_frames as f64) * 1e9 / last.sample_rate as f64;
        let start_ns = first.at_ns as f64 - first.position_frames as f64 * 1e9 / first.sample_rate as f64;
        let gap_ms = (start_ns - end_ns) / 1e6;
        let reopened = last.sample_rate != first.sample_rate;
        println!(
            "  {} → {}: {gap_ms:+.2} ms{}",
            pair[0],
            pair[1],
            if reopened { " (rate change: the device reopened)" } else { "" }
        );
    }
    Ok(())
}
