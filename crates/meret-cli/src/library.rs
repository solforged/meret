//! `meret library …`: the library through `meret-api`, as the app sees it.
//! Scan a folder into the store, page through a query, and play results
//! through the queue, timing every join.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Result, anyhow};
use meret_api::{Api, StatusDto, TargetDto, ThreadDto, ThreadKind, TransportDto};
use meret_api::{ItemDto, ViewDto};
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
    let rt = tokio::runtime::Builder::new_current_thread().enable_time().enable_io().build()?;
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

pub fn remove(api: &Api, id: i64) -> Result<()> {
    api.remove_root(id).map_err(|e| anyhow!(e))?;
    println!("removed root {id}; the table holds {} tracks", api.status().tracks);
    Ok(())
}

pub fn suggest(api: &Api) -> Result<()> {
    for folder in api.suggest_folders() {
        let count = folder.audio_files.map(|n| format!("{n}{} audio files", if folder.more { "+" } else { "" }))
            .unwrap_or_else(|| "count after access".into());
        println!("{}: {} · {}{}{}",
            folder.label, folder.path, count,
            if folder.asks_permission { " · macOS will ask for access" } else { "" },
            if folder.note.is_empty() { String::new() } else { format!(" · {}", folder.note) });
    }
    Ok(())
}

pub fn rescan(api: &Api, rt: &tokio::runtime::Runtime) -> Result<()> {
    let t = Instant::now();
    settle(api, rt);
    api.rescan();
    settle(api, rt);
    let covers = api.cover_report();
    println!(
        "rescanned in {:.2?}; the table holds {} tracks; read covers for {} releases, found {}, wrote {} files ({} unreadable)",
        t.elapsed(), api.status().tracks, covers.checked, covers.found, covers.files, covers.unreadable
    );
    Ok(())
}

pub fn ls(api: &Api, rt: &tokio::runtime::Runtime, query: &str, view: ViewDto, offset: u64, limit: u32) -> Result<()> {
    settle(api, rt);
    let t = Instant::now();
    let page = api.rows(query, view, offset, limit).map_err(|e| anyhow!(e))?;
    let took = t.elapsed();
    for item in &page.items {
        match item {
            ItemDto::Group(g) => println!(
                "\n  {} · {} · {} · {} tracks · {}:{:02} · {}",
                g.title,
                g.album_artist.as_deref().unwrap_or(""),
                g.year.map(|y| y.to_string()).unwrap_or_default(),
                g.tracks,
                g.length_ms / 60_000,
                g.length_ms / 1000 % 60,
                g.format
            ),
            ItemDto::Track { ordinal, row: r } => {
                let len = r.length_ms.map(|ms| format!("{}:{:02}", ms / 60_000, ms / 1000 % 60)).unwrap_or_default();
                println!(
                    "{ordinal:>6}  {:>2}-{:<3} {:<40.40} {:<24.24} {:<32.32} {:>4} {:>6}  {}",
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
        }
    }
    println!("{} of {} items · {} tracks · {} releases in {took:.2?}", page.items.len(), page.total, page.tracks, page.releases);
    Ok(())
}

pub fn facets(api: &Api, rt: &tokio::runtime::Runtime, query: &str) -> Result<()> {
    settle(api, rt);
    let facets = api.facets(query).map_err(|e| anyhow!(e))?;
    for (label, column) in [("Idioms", facets.idioms), ("People", facets.people), ("Releases", facets.releases)] {
        println!("{label} · {} tracks · All → {}", column.tracks, column.all_query);
        for entry in column.entries {
            println!("  {} {:>6}  {}  → {}", if entry.selected { "*" } else { " " }, entry.tracks, entry.name, entry.query);
        }
    }
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

/// Walk numbered hits/threads, or navigate between session trails.
pub fn walk(api: &Api, rt: &tokio::runtime::Runtime, search: &str, steps: &[String]) -> Result<()> {
    settle(api, rt);
    let mut trail = if search == "[" {
        api.trail_back().ok_or_else(|| anyhow!("there's no saved trail"))?
    } else {
        api.start_trail(TargetDto::Search { query: search.into() })
    };
    let target = &trail.stops.iter().find(|stop| stop.index == trail.current).expect("current stop").target;
    let mut lines = walk_pane(api, target)?;
    print_strip(&trail);
    for step in steps {
        trail = match step.as_str() {
            "[" => api.trail_back().ok_or_else(|| anyhow!("there's no previous trail stop"))?,
            "]" => api.trail_forward().ok_or_else(|| anyhow!("there's no next trail stop"))?,
            _ if step.starts_with("search=") => api.start_trail(TargetDto::Search { query: step["search=".len()..].into() }),
            _ => {
                let index: usize = step.parse().map_err(|_| anyhow!("expected a line number, '[', ']', or 'search=QUERY', got {step:?}"))?;
                let (via, to, _) = lines.get(index).cloned().ok_or_else(|| anyhow!("there's no line {index}"))?;
                api.follow(trail.current, to, via).map_err(|e| anyhow!(e))?
            }
        };
        let target = &trail.stops.iter().find(|stop| stop.index == trail.current).expect("current stop").target;
        lines = walk_pane(api, target)?;
        print_strip(&trail);
    }
    Ok(())
}

pub fn trails(api: &Api, limit: u32) -> Result<()> {
    for trail in api.trail_history(limit).map_err(anyhow::Error::msg)? {
        println!("{}  · {} stops · {} branches · {} played · {} wanted{}{}",
            trail.title, trail.stops, trail.branches, trail.played, trail.wanted,
            if trail.kept { " · kept" } else { "" },
            trail.name.map(|name| format!(" · {name}")).unwrap_or_default());
    }
    Ok(())
}

fn walk_pane(api: &Api, target: &TargetDto) -> Result<Vec<(ThreadKind, TargetDto, String)>> {
    let t = Instant::now();
    let lines: Vec<_> = match target {
        TargetDto::Search { query } => {
            let s = api.search(query).map_err(|e| anyhow!(e))?;
            println!("\nsearch {}: {} tracks", s.query, s.tracks);
            s.people
                .iter()
                .map(|h| (ThreadKind::Matched, TargetDto::Person { id: h.id }, format!("{} · {}", h.title, h.detail)))
                .chain(s.releases.iter().map(|h| (ThreadKind::Matched, TargetDto::Release { id: h.id }, format!("{} · {}", h.title, h.detail))))
                .collect()
        }
        TargetDto::Release { id } => {
            let r = api.release(*id).map_err(|e| anyhow!(e))?;
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
            if let Some(cover) = &r.cover {
                println!("    cover {cover}");
            }
            for row in &r.rows {
                let artist = row.artist.as_deref().filter(|a| Some(*a) != r.artist.as_deref()).unwrap_or("");
                println!("    {}-{:02} {:<44.44} {artist}", row.disc, row.number, row.title);
            }
            r.credits.iter().map(|c| (c.kind, c.to.clone(), thread_line(&c.label, c))).collect()
        }
        TargetDto::Person { id } => {
            let p = api.person(*id).map_err(|e| anyhow!(e))?;
            println!("\n{} · {} tracks  ({:.2?})", p.name, p.tracks, t.elapsed());
            [("releases", &p.releases), ("on", &p.appears_on), ("worked with", &p.worked_with)]
                .into_iter()
                .flat_map(|(group, list)| list.iter().map(move |c| (c.kind, c.to.clone(), thread_line(group, c))))
                .collect()
        }
    };
    print_lines(&lines);
    Ok(lines)
}

fn print_strip(trail: &meret_api::TrailDto) {
    let mut path: Vec<_> = trail.stops.iter().filter(|s| s.on_path).collect();
    path.sort_by_key(|s| s.index);
    let strip: Vec<String> = path
        .into_iter()
        .map(|s| match &s.via {
            Some(via) => format!("—{via}→ {}", s.title),
            None => s.title.clone(),
        })
        .collect();
    println!("\ntrail: {}  ({} stops total; current {})", strip.join(" "), trail.stops.len(), trail.current);
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
    api.play_results(query, ViewDto::default(), opts.from).map_err(|e| anyhow!(e))?;
    let uris: HashMap<u64, String> = api.queue().into_iter().collect();
    println!("queued {} items", uris.len());

    let t = Instant::now();
    let mut order: Vec<String> = vec![];
    let mut heard: HashMap<u64, Heard> = HashMap::new();
    let mut started: Vec<u64> = vec![];
    let mut ended = 0usize;
    rt.block_on(async {
        let interrupt = tokio::signal::ctrl_c();
        tokio::pin!(interrupt);
        let mut interrupted = false;
        loop {
            // Anchors are only sent on a change, so a long track can be
            // silent for its whole length; wait for Idle.
            let received = tokio::select! {
                event = events.recv() => event,
                _ = &mut interrupt, if !interrupted => {
                    interrupted = true;
                    api.transport(TransportDto::Stop).map_err(anyhow::Error::msg)?;
                    continue;
                }
            };
            let e = match received {
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
                EngineEvent::OutputChanged { .. } => {}
            }
        }
        Ok::<(), anyhow::Error>(())
    })?;

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

pub fn history(api: &Api, limit: u32) -> Result<()> {
    for row in api.history(limit).map_err(anyhow::Error::msg)? {
        let seconds = row.started_at_ms / 1000;
        let time = format!("{:02}:{:02}:{:02} UTC", seconds.rem_euclid(86_400) / 3600, seconds.rem_euclid(3600) / 60, seconds.rem_euclid(60));
        let duration = |ms: u64| format!("{}:{:02}", ms / 60_000, ms / 1000 % 60);
        let length = row.length_ms.map(duration).unwrap_or_else(|| "?".into());
        println!("{time}  {:<40.40} {:<24.24} {}/{} {}", row.title, row.credit.as_deref().unwrap_or(""),
            duration(row.played_ms), length, if row.counted { "✓" } else { "" });
    }
    Ok(())
}

pub fn resume(api: &Api, limit: u32) -> Result<()> {
    let rows = api.resume_points(limit).map_err(anyhow::Error::msg)?;
    for row in &rows {
        println!("{} · {} · {} · {}-{} {} · {}:{:02} / {} · updated {}",
            row.release_id, row.title, row.credit.as_deref().unwrap_or(""), row.disc, row.number,
            row.recording_title, row.position_ms / 60_000, row.position_ms / 1000 % 60,
            row.length_ms.map(|ms| format!("{}:{:02}", ms / 60_000, ms / 1000 % 60)).unwrap_or_default(),
            row.updated_at);
    }
    println!("{} resume points", rows.len());
    Ok(())
}

pub fn now(api: &Api) -> Result<()> {
    let now = api.now();
    let (position, rate) = now.anchor.map(|a| (a.position_ms, a.rate)).unwrap_or_default();
    println!("{} · {} · {} at {:.0} ms / {:?} ms · track {:?} · release {:?}",
        now.title, now.subtitle, if rate > 0.0 { "playing" } else { "paused" },
        position, now.length_ms, now.track_id, now.release_id);
    Ok(())
}
