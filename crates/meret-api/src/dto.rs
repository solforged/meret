//! Plain data for the UI. Flat structs and simple enums, so flutter_rust_bridge
//! (and later a websocket) can carry them without custom codecs.

use meret_core::{NowState, StatusState};
use meret_store::TrackRow;
use meret_graph::Trail;
use meret_model::signal::Fidelity;

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
