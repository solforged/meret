//! Plain data for the UI. Flat structs and simple enums, so flutter_rust_bridge
//! (and later a websocket) can carry them without custom codecs.

use meret_core::{Front, NowState, PersonPage, ReleasePage, Search, StatusState};
use meret_graph::Trail;
use meret_model::signal::Fidelity;
use meret_model::thread::source_label;
use meret_model::{AgentId, EntityRef, Idiom, ReleaseId};
use meret_query::{NameField, Term};
use meret_store::{TrackRow, format_code};

pub use meret_model::ThreadKind;

#[derive(Clone, Debug, PartialEq)]
pub enum QueryKind {
    Search,
    Command,
    Invalid,
}

#[derive(Clone, Debug, PartialEq)]
pub struct QueryDto {
    pub kind: QueryKind,
    pub canonical: String,
    pub error: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ColumnDto {
    Year,
    Length,
    Plays,
    LastPlayed,
    Added,
    Dr,
}

#[derive(Clone, Debug, PartialEq)]
pub struct HistogramDto {
    pub lo: f64,
    pub hi: f64,
    pub bins: Vec<u32>,
    pub matched: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub enum TransportDto {
    PlayFile { path: String },
    Pause,
    Resume,
    Seek { ms: u64 },
    Stop,
}

/// The playhead, for the UI to extrapolate every vsync:
/// `position = position_ms + rate × (now − received_at)`.
#[derive(Clone, Debug, PartialEq)]
pub struct AnchorDto {
    pub item: u64,
    pub position_ms: f64,
    pub rate: f64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StageDto {
    pub name: String,
    pub detail: String,
    pub alters: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub enum FidelityDto {
    BitPerfect,
    Altered,
    Lossy,
}

#[derive(Clone, Debug, PartialEq)]
pub struct NowDto {
    pub title: String,
    pub subtitle: String,
    pub anchor: Option<AnchorDto>,
    pub length_ms: Option<u64>,
    pub path: Vec<StageDto>,
    pub fidelity: Option<FidelityDto>,
    pub error: Option<String>,
}

impl From<&NowState> for NowDto {
    fn from(n: &NowState) -> Self {
        let now = meret_engine::clock::now_ns();
        NowDto {
            title: n.title.clone(),
            subtitle: n.subtitle.clone(),
            // Re-based to "now", so the receiver can treat it as fresh.
            anchor: n.anchor.map(|a| AnchorDto { item: a.item, position_ms: a.seconds_at(now) * 1000.0, rate: a.rate }),
            length_ms: n.length_ms,
            path: n
                .path
                .iter()
                .flat_map(|p| p.stages.iter())
                .map(|s| StageDto { name: s.name.clone(), detail: s.detail.clone(), alters: s.alters })
                .collect(),
            fidelity: n.path.as_ref().map(|p| match p.fidelity() {
                Fidelity::BitPerfect => FidelityDto::BitPerfect,
                Fidelity::Altered => FidelityDto::Altered,
                Fidelity::Lossy => FidelityDto::Lossy,
            }),
            error: n.error.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SourceDto {
    pub name: String,
    pub detail: String,
    pub ok: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct JobDto {
    pub verb: String,
    pub done: u64,
    pub total: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StatusDto {
    pub sources: Vec<SourceDto>,
    pub jobs: Vec<JobDto>,
    pub guessed: u64,
    pub new_leads: u64,
    /// Tracks in the table.
    pub tracks: u64,
    /// Changes whenever the library's rows do; a list refetches when it moves.
    pub library_version: u64,
}

impl From<&StatusState> for StatusDto {
    fn from(s: &StatusState) -> Self {
        StatusDto {
            sources: s.sources.iter().map(|x| SourceDto { name: x.name.clone(), detail: x.detail.clone(), ok: x.ok }).collect(),
            jobs: s.jobs.iter().map(|j| JobDto { verb: j.verb.clone(), done: j.done, total: j.total }).collect(),
            guessed: s.guessed,
            new_leads: s.new_leads,
            tracks: s.tracks,
            library_version: s.library_version,
        }
    }
}

/// One row of the table.
#[derive(Clone, Debug, PartialEq)]
pub struct TrackRowDto {
    pub track_id: i64,
    pub title: String,
    pub artist: Option<String>,
    pub artist_id: Option<i64>,
    pub album: String,
    pub album_artist: Option<String>,
    pub album_artist_id: Option<i64>,
    pub release_id: i64,
    pub disc: u32,
    pub number: u32,
    pub year: Option<u16>,
    pub length_ms: Option<u64>,
    /// "FLAC 16/44.1", "AAC".
    pub format: String,
    pub path: Option<String>,
}

impl From<TrackRow> for TrackRowDto {
    fn from(r: TrackRow) -> Self {
        let format = match (r.codec, r.bits, r.sample_rate) {
            (Some(codec), Some(bits), Some(rate)) => {
                let khz = rate as f64 / 1000.0;
                if khz.fract() == 0.0 { format!("{codec} {bits}/{khz:.0}") } else { format!("{codec} {bits}/{khz:.1}") }
            }
            (Some(codec), _, _) => codec,
            (None, _, _) => String::new(),
        };
        TrackRowDto {
            track_id: r.track.0,
            title: r.title,
            artist: r.artist,
            artist_id: r.artist_id.map(|a| a.0),
            album: r.album,
            album_artist: r.album_artist,
            album_artist_id: r.album_artist_id.map(|a| a.0),
            release_id: r.release.0,
            disc: r.disc,
            number: r.number,
            year: r.year,
            length_ms: r.length_ms,
            format,
            path: r.path,
        }
    }
}

/// A page of a query's result.
#[derive(Clone, Debug, PartialEq)]
pub struct RowsDto {
    pub total: u64,
    pub offset: u64,
    pub rows: Vec<TrackRowDto>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum HitKind {
    Person,
    Release,
    Track,
}

/// One line of the query line's hits.
#[derive(Clone, Debug, PartialEq)]
pub struct HitDto {
    pub kind: HitKind,
    /// The agent, release or track.
    pub id: i64,
    pub title: String,
    /// "34 tracks"; "Iona · 1993 · 11 tracks"; "Iona · Open Sky".
    pub detail: String,
    /// What opening it shows as a table: `by:"Iona"`, `release:"Open Sky"`,
    /// or for a track the search it came from.
    pub query: String,
    /// For a track, its row in `query`'s result, to play from.
    pub index: Option<u64>,
}

/// What the query line shows as you type a search.
#[derive(Clone, Debug, PartialEq)]
pub struct SearchDto {
    /// The search in canonical form; opening it as a table uses this.
    pub query: String,
    /// How many tracks the whole search matches.
    pub tracks: u64,
    pub people: Vec<HitDto>,
    pub people_total: u64,
    pub releases: Vec<HitDto>,
    pub releases_total: u64,
    /// Tracks in the result whose title has the typed words, in library
    /// order; the result's first rows when nothing was typed but clauses.
    pub track_hits: Vec<HitDto>,
    pub track_hits_total: u64,
}

impl From<Search> for SearchDto {
    fn from(s: Search) -> Self {
        let n = |n: u32| format!("{n} {}", if n == 1 { "track" } else { "tracks" });
        SearchDto {
            people: s
                .people
                .into_iter()
                .map(|p| HitDto {
                    kind: HitKind::Person,
                    id: p.agent.0,
                    detail: n(p.tracks),
                    query: Term::Person { role: None, name: p.name.clone() }.to_string(),
                    title: p.name,
                    index: None,
                })
                .collect(),
            releases: s
                .releases
                .into_iter()
                .map(|r| HitDto {
                    kind: HitKind::Release,
                    id: r.release.0,
                    detail: [r.artist, r.year.map(|y| y.to_string()), Some(n(r.tracks))].into_iter().flatten().collect::<Vec<_>>().join(" · "),
                    query: Term::Named { field: NameField::Release, value: r.title.clone() }.to_string(),
                    title: r.title,
                    index: None,
                })
                .collect(),
            track_hits: s
                .track_hits
                .into_iter()
                .map(|(i, r)| HitDto {
                    kind: HitKind::Track,
                    id: r.track.0,
                    detail: [r.artist, Some(r.album)].into_iter().flatten().collect::<Vec<_>>().join(" · "),
                    query: s.query.clone(),
                    title: r.title,
                    index: Some(i as u64),
                })
                .collect(),
            query: s.query,
            tracks: s.tracks as u64,
            track_hits_total: s.track_hits_total as u64,
            people_total: s.people_total,
            releases_total: s.releases_total,
        }
    }
}

/// The Front: one flat page of doors into the library (plate 02). Only
/// what the library can answer; leads, crates and trails join it as they
/// exist. A line with a `query` opens it as a table.
#[derive(Clone, Debug, PartialEq)]
pub struct FrontDto {
    pub tracks: u64,
    pub releases: u64,
    /// Idioms with at least one release, in the order of idioms.md.
    pub idioms: Vec<IdiomLineDto>,
    /// What you own by format, largest first; the lines don't overlap.
    pub formats: Vec<FrontLineDto>,
    /// Releases, newest first.
    pub added_lately: Vec<RecentDto>,
    /// Things to fix, only those that are non-zero.
    pub needs_you: Vec<FrontLineDto>,
    pub roots: Vec<RootDto>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct IdiomLineDto {
    /// "Albums", "Scores"…
    pub label: String,
    pub releases: u64,
    pub tracks: u64,
    pub query: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FrontLineDto {
    pub label: String,
    pub count: u64,
    pub note: String,
    pub query: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecentDto {
    pub release_id: i64,
    pub title: String,
    pub artist: Option<String>,
    pub year: Option<u16>,
    pub tracks: u32,
    /// Unix milliseconds.
    pub added_ms: i64,
    pub query: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RootDto {
    pub id: i64,
    pub path: String,
    pub online: bool,
}

impl From<Front> for FrontDto {
    fn from(f: Front) -> Self {
        let mut idioms: Vec<IdiomLineDto> = Idiom::ALL
            .into_iter()
            .map(|i| IdiomLineDto {
                label: plural(i).into(),
                releases: f.facts.releases_by_idiom[i as usize],
                tracks: f.tracks_by_idiom[i as usize] as u64,
                query: Some(format!("idiom:{}", i.as_str())),
            })
            .collect();
        idioms.push(IdiomLineDto {
            label: "Not sorted yet".into(),
            releases: f.facts.releases_by_idiom[0],
            tracks: f.tracks_by_idiom[0] as u64,
            query: None,
        });
        idioms.retain(|l| l.releases > 0);

        use format_code::*;
        let by = |code: u8| f.tracks_by_format[code as usize];
        let line = |label: &str, count, note: &str, query: Option<&str>| FrontLineDto {
            label: label.into(),
            count,
            note: note.into(),
            query: query.map(Into::into),
        };
        let mut formats = vec![
            line("Lossless, up to 16/48", by(FLAC_CD), "FLAC, ALAC, WAV, AIFF", Some("format:flac -format:hires")),
            line("Hi-res", by(HI_RES), "over 16 bit or 48 kHz", Some("format:hires")),
            line("DSD", by(DSD), "", Some("format:dsd")),
            line("Native chiptune", by(CHIPTUNE), "SPC, NSF, VGM", Some("format:chiptune")),
            line("Lossy", by(LOSSY), "MP3, AAC, Ogg, Opus", Some("format:lossy")),
            line("Unknown format", by(UNKNOWN), "", None),
        ];
        formats.retain(|l| l.count > 0);
        formats.sort_by_key(|l| std::cmp::Reverse(l.count));

        let offline = f.roots.iter().filter(|r| !r.online).count() as u64;
        let mut needs_you = vec![
            line("Files whose tags can't be read", f.facts.unreadable, "tried again on every scan", None),
            line("Tracks with no artist tag", f.facts.no_artist, "they sort last", None),
            line("Files that have gone", f.facts.missing, "kept, with their plays", None),
            line("Folders not connected", offline, "their tracks come back when they do", None),
        ];
        needs_you.retain(|l| l.count > 0);

        FrontDto {
            tracks: f.tracks,
            releases: f.facts.releases_by_idiom.iter().sum(),
            idioms,
            formats,
            added_lately: f
                .facts
                .added_lately
                .into_iter()
                .map(|r| RecentDto {
                    query: Term::Named { field: NameField::Release, value: r.title.clone() }.to_string(),
                    release_id: r.release.0,
                    title: r.title,
                    artist: r.artist,
                    year: r.year,
                    tracks: r.tracks,
                    added_ms: r.added_ms,
                })
                .collect(),
            needs_you,
            roots: f
                .roots
                .into_iter()
                .map(|r| RootDto { id: r.id.0, path: r.path.display().to_string(), online: r.online })
                .collect(),
        }
    }
}

fn plural(i: Idiom) -> &'static str {
    match i {
        Idiom::Album => "Albums",
        Idiom::Song => "Songs",
        Idiom::Work => "Works",
        Idiom::Session => "Sessions",
        Idiom::Score => "Scores",
        Idiom::Set => "Sets",
        Idiom::Spoken => "Spoken",
    }
}

/// What a pane is about, and where a thread can lead.
#[derive(Clone, Debug, PartialEq)]
pub enum TargetDto {
    /// A search; only ever a trail's root.
    Search { query: String },
    Release { id: i64 },
    Person { id: i64 },
}

impl TargetDto {
    /// The trail stop, and the root query a search carries.
    pub fn entity(&self) -> (EntityRef, Option<String>) {
        match self {
            TargetDto::Search { query } => (EntityRef::Search, Some(query.clone())),
            TargetDto::Release { id } => (EntityRef::Release(ReleaseId(*id)), None),
            TargetDto::Person { id } => (EntityRef::Agent(AgentId(*id)), None),
        }
    }

    fn of(e: EntityRef, root_query: Option<&str>) -> Self {
        match e {
            EntityRef::Search => TargetDto::Search { query: root_query.unwrap_or_default().into() },
            EntityRef::Release(r) => TargetDto::Release { id: r.0 },
            EntityRef::Agent(a) => TargetDto::Person { id: a.0 },
            // Only `Api` writes the trail, and it only opens these three.
            other => unreachable!("{other:?} is not a pane yet"),
        }
    }
}

/// A thread out of a pane. Following it opens `to` to the right.
#[derive(Clone, Debug, PartialEq)]
pub struct ThreadDto {
    pub kind: ThreadKind,
    /// "by", "album artist", "on", "worked with".
    pub label: String,
    /// "tags", "your library".
    pub source: String,
    pub to: TargetDto,
    pub title: String,
    /// "1-03, 1-07"; "2010 · 12 tracks"; "3 releases".
    pub detail: String,
}

impl ThreadDto {
    fn local(kind: ThreadKind, to: TargetDto, title: String, detail: String) -> Self {
        ThreadDto { kind, label: kind.label().into(), source: source_label(LOCAL_TAGS).into(), to, title, detail }
    }
}

/// Threads read from file tags.
pub(crate) const LOCAL_TAGS: &str = "local_tags";

/// A release pane (plate 01, the middle pane).
#[derive(Clone, Debug, PartialEq)]
pub struct ReleaseDto {
    pub id: i64,
    pub title: String,
    /// The album artist.
    pub artist: Option<String>,
    pub year: Option<u16>,
    /// "Score", "Album"; None when not sorted yet.
    pub idiom: Option<String>,
    pub tracks: u32,
    pub discs: u32,
    pub length_ms: u64,
    /// Its files' formats, most tracks first: "FLAC 16/44.1", "MP3".
    pub formats: Vec<String>,
    /// The tracklist; row i plays with `play_release(id, i)`.
    pub rows: Vec<TrackRowDto>,
    /// The album artist, then each track artist and where they are.
    pub credits: Vec<ThreadDto>,
}

impl From<ReleasePage> for ReleaseDto {
    fn from(p: ReleasePage) -> Self {
        let rows: Vec<TrackRowDto> = p.tracks.into_iter().map(TrackRowDto::from).collect();
        let mut discs: Vec<u32> = rows.iter().map(|r| r.disc).collect();
        discs.sort_unstable();
        discs.dedup();
        let mut formats: Vec<(String, usize)> = vec![];
        for r in rows.iter().filter(|r| !r.format.is_empty()) {
            match formats.iter_mut().find(|(f, _)| *f == r.format) {
                Some((_, n)) => *n += 1,
                None => formats.push((r.format.clone(), 1)),
            }
        }
        formats.sort_by_key(|(_, n)| std::cmp::Reverse(*n));

        let mut credits = vec![];
        if let Some((agent, name)) = &p.album_artist {
            credits.push(ThreadDto::local(ThreadKind::AlbumArtist, TargetDto::Person { id: agent.0 }, name.clone(), String::new()));
        }
        for a in p.artists {
            let everywhere = a.positions.len() == rows.len();
            // The album artist on every track is already said.
            if everywhere && p.album_artist.as_ref().is_some_and(|(id, _)| *id == a.agent) {
                continue;
            }
            let detail = if everywhere {
                format!("all {} tracks", rows.len())
            } else if a.positions.len() > 6 {
                format!("{} tracks", a.positions.len())
            } else {
                let multi = discs.len() > 1;
                a.positions.iter().map(|&(d, n)| if multi { format!("{d}-{n:02}") } else { n.to_string() }).collect::<Vec<_>>().join(", ")
            };
            credits.push(ThreadDto::local(ThreadKind::By, TargetDto::Person { id: a.agent.0 }, a.name, detail));
        }

        ReleaseDto {
            id: p.release.0,
            title: p.title,
            artist: p.album_artist.map(|(_, name)| name),
            year: p.year,
            idiom: p.idiom.map(|i| singular(i).into()),
            tracks: rows.len() as u32,
            discs: discs.len() as u32,
            length_ms: rows.iter().filter_map(|r| r.length_ms).sum(),
            formats: formats.into_iter().map(|(f, _)| f).collect(),
            rows,
            credits,
        }
    }
}

/// A person pane (plate 01, the first pane). Groups are people here too.
#[derive(Clone, Debug, PartialEq)]
pub struct PersonDto {
    pub id: i64,
    pub name: String,
    /// Their tracks: all of their own releases', and theirs on others'.
    pub tracks: u32,
    /// Releases they're the album artist of, by year.
    pub releases: Vec<ThreadDto>,
    /// Other people's releases they're on, by year.
    pub appears_on: Vec<ThreadDto>,
    /// People who share releases with them, most shared first.
    pub worked_with: Vec<ThreadDto>,
}

impl From<PersonPage> for PersonDto {
    fn from(p: PersonPage) -> Self {
        let n = |n: u32, one: &str, many: &str| format!("{n} {}", if n == 1 { one } else { many });
        let release = |r: meret_core::PersonRelease, own: bool| {
            let count = if own { n(r.tracks, "track", "tracks") } else { format!("{} of {}", r.theirs, n(r.tracks, "track", "tracks")) };
            let detail = r.year.map(|y| format!("{y} · {count}")).unwrap_or(count);
            ThreadDto::local(ThreadKind::AppearsOn, TargetDto::Release { id: r.release.0 }, r.title, detail)
        };
        PersonDto {
            id: p.agent.0,
            name: p.name,
            tracks: p.tracks,
            releases: p.releases.into_iter().map(|r| release(r, true)).collect(),
            appears_on: p.appears_on.into_iter().map(|r| release(r, false)).collect(),
            worked_with: p
                .worked_with
                .into_iter()
                .map(|c| {
                    let detail = n(c.releases, "release", "releases");
                    ThreadDto::local(ThreadKind::WorkedWith, TargetDto::Person { id: c.agent.0 }, c.name, detail)
                })
                .collect(),
        }
    }
}

fn singular(i: Idiom) -> &'static str {
    match i {
        Idiom::Album => "Album",
        Idiom::Song => "Song",
        Idiom::Work => "Work",
        Idiom::Session => "Session",
        Idiom::Score => "Score",
        Idiom::Set => "Set",
        Idiom::Spoken => "Spoken",
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StopDto {
    pub index: u32,
    pub parent: Option<u32>,
    pub target: TargetDto,
    /// The release's title, the person's name, or the search.
    pub title: String,
    /// The thread into this stop: "on". None for the root.
    pub via: Option<String>,
    /// Where that thread came from: "tags".
    pub via_source: Option<String>,
    pub on_path: bool,
    pub is_fork: bool,
    pub is_peek: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TrailDto {
    pub root_query: Option<String>,
    pub current: u32,
    pub stops: Vec<StopDto>,
    pub meetings: Vec<(u32, u32)>,
}

impl TrailDto {
    /// `title` names a stop: a release's title, a person's name.
    pub fn from_trail(t: &Trail, now: i64, title: impl Fn(&TargetDto) -> String) -> Self {
        let path = t.path();
        let forks = t.forks(now);
        let stops = (0..t.len())
            .filter(|&i| !t.stop(i).pruned)
            .map(|i| {
                let s = t.stop(i);
                let target = TargetDto::of(s.entity, t.root_query.as_deref());
                StopDto {
                    index: i as u32,
                    parent: s.parent.map(|p| p as u32),
                    title: title(&target),
                    target,
                    via: s.via.as_ref().map(|v| v.kind.label().to_string()),
                    via_source: s.via.as_ref().map(|v| source_label(&v.source).to_string()),
                    on_path: path.contains(&i),
                    is_fork: forks.contains(&i),
                    is_peek: t.is_peek(i, now),
                }
            })
            .collect();
        TrailDto {
            root_query: t.root_query.clone(),
            current: t.current() as u32,
            stops,
            meetings: t.meetings().into_iter().map(|(a, b)| (a as u32, b as u32)).collect(),
        }
    }
}
