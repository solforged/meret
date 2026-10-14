//! Mirrors of `meret_api` DTOs, declared here so codegen sees them.

use flutter_rust_bridge::frb;
pub use meret_api::{
    AnchorDto, ColumnDto, FidelityDto, HistogramDto, JobDto, NowDto, QueryDto, QueryKind, SourceDto, StageDto,
    StatusDto, StopDto, TrailDto, TransportDto,
};

#[frb(mirror(QueryKind))]
pub enum _QueryKind {
    Search,
    Command,
    Invalid,
}

#[frb(mirror(QueryDto))]
pub struct _QueryDto {
    pub kind: QueryKind,
    pub canonical: String,
    pub error: Option<String>,
}

#[frb(mirror(ColumnDto))]
pub enum _ColumnDto {
    Year,
    Length,
    Plays,
    LastPlayed,
    Added,
    Dr,
}

#[frb(mirror(HistogramDto))]
pub struct _HistogramDto {
    pub lo: f64,
    pub hi: f64,
    pub bins: Vec<u32>,
    pub matched: u64,
}

#[frb(mirror(TransportDto))]
pub enum _TransportDto {
    PlayFile { path: String },
    Pause,
    Resume,
    Seek { ms: u64 },
    Stop,
}

#[frb(mirror(AnchorDto))]
pub struct _AnchorDto {
    pub item: u64,
    pub position_ms: f64,
    pub rate: f64,
}

#[frb(mirror(StageDto))]
pub struct _StageDto {
    pub name: String,
    pub detail: String,
    pub alters: bool,
}

#[frb(mirror(FidelityDto))]
pub enum _FidelityDto {
    BitPerfect,
    Altered,
    Lossy,
}

#[frb(mirror(NowDto))]
pub struct _NowDto {
    pub title: String,
    pub subtitle: String,
    pub anchor: Option<AnchorDto>,
    pub length_ms: Option<u64>,
    pub path: Vec<StageDto>,
    pub fidelity: Option<FidelityDto>,
    pub error: Option<String>,
}

#[frb(mirror(SourceDto))]
pub struct _SourceDto {
    pub name: String,
    pub detail: String,
    pub ok: bool,
}

#[frb(mirror(JobDto))]
pub struct _JobDto {
    pub verb: String,
    pub done: u64,
    pub total: u64,
}

#[frb(mirror(StatusDto))]
pub struct _StatusDto {
    pub sources: Vec<SourceDto>,
    pub jobs: Vec<JobDto>,
    pub guessed: u64,
    pub new_leads: u64,
}

#[frb(mirror(StopDto))]
pub struct _StopDto {
    pub index: u32,
    pub parent: Option<u32>,
    pub entity: String,
    pub via: Option<String>,
    pub on_path: bool,
    pub is_fork: bool,
    pub is_peek: bool,
}

#[frb(mirror(TrailDto))]
pub struct _TrailDto {
    pub root_query: Option<String>,
    pub current: u32,
    pub stops: Vec<StopDto>,
    pub meetings: Vec<(u32, u32)>,
}
