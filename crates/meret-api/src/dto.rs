//! Plain data for the UI. Flat structs and simple enums, so flutter_rust_bridge
//! (and later a websocket) can carry them without custom codecs.

use meret_core::{Front, NowState, StatusState};
use meret_graph::Trail;
use meret_model::Idiom;
use meret_model::signal::Fidelity;
use meret_query::{NameField, Term};
use meret_store::{TrackRow, format_code};

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
    pub album: String,
    pub album_artist: Option<String>,
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
            album: r.album,
            album_artist: r.album_artist,
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

#[derive(Clone, Debug, PartialEq)]
pub struct StopDto {
    pub index: u32,
    pub parent: Option<u32>,
    /// "agent:10", "release:20".
    pub entity: String,
    /// The thread into this stop: "composed by".
    pub via: Option<String>,
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
    pub fn from_trail(t: &Trail, now: i64) -> Self {
        let path = t.path();
        let forks = t.forks(now);
        let stops = (0..t.len())
            .filter(|&i| !t.stop(i).pruned)
            .map(|i| {
                let s = t.stop(i);
                let entity = serde_json::to_value(s.entity)
                    .ok()
                    .map(|v| format!("{}:{}", v["kind"].as_str().unwrap_or(""), v["id"]))
                    .unwrap_or_default();
                StopDto {
                    index: i as u32,
                    parent: s.parent.map(|p| p as u32),
                    entity,
                    via: s.via.as_ref().map(|v| v.kind.label().to_string()),
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
