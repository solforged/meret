//! Mirrors of `meret_api` DTOs, declared here so codegen sees them.

use flutter_rust_bridge::frb;
pub use meret_api::{
    AnchorDto, ColumnDto, FidelityDto, FrontDto, FrontLineDto, HistogramDto, HitDto, HitKind, IdiomLineDto, JobDto,
    NowDto, QueryDto, QueryKind, RecentDto, RootDto, RowsDto, SearchDto, SourceDto, StageDto, StatusDto, StopDto,
    TrackRowDto, TrailDto, TransportDto,
};

#[frb(mirror(HitKind))]
pub enum _HitKind {
    Person,
    Release,
    Track,
}

#[frb(mirror(HitDto))]
pub struct _HitDto {
    pub kind: HitKind,
    pub id: i64,
    pub title: String,
    pub detail: String,
    pub query: String,
    pub index: Option<u64>,
}

#[frb(mirror(SearchDto))]
pub struct _SearchDto {
    pub query: String,
    pub tracks: u64,
    pub people: Vec<HitDto>,
    pub people_total: u64,
    pub releases: Vec<HitDto>,
    pub releases_total: u64,
    pub track_hits: Vec<HitDto>,
    pub track_hits_total: u64,
}

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
    pub tracks: u64,
    pub library_version: u64,
}

#[frb(mirror(TrackRowDto))]
pub struct _TrackRowDto {
    pub track_id: i64,
    pub title: String,
    pub artist: Option<String>,
    pub album: String,
    pub album_artist: Option<String>,
    pub disc: u32,
    pub number: u32,
    pub year: Option<u16>,
    pub length_ms: Option<u64>,
    pub format: String,
    pub path: Option<String>,
}

#[frb(mirror(RowsDto))]
pub struct _RowsDto {
    pub total: u64,
    pub offset: u64,
    pub rows: Vec<TrackRowDto>,
}

#[frb(mirror(FrontDto))]
pub struct _FrontDto {
    pub tracks: u64,
    pub releases: u64,
    pub idioms: Vec<IdiomLineDto>,
    pub formats: Vec<FrontLineDto>,
    pub added_lately: Vec<RecentDto>,
    pub needs_you: Vec<FrontLineDto>,
    pub roots: Vec<RootDto>,
}

#[frb(mirror(IdiomLineDto))]
pub struct _IdiomLineDto {
    pub label: String,
    pub releases: u64,
    pub tracks: u64,
    pub query: Option<String>,
}

#[frb(mirror(FrontLineDto))]
pub struct _FrontLineDto {
    pub label: String,
    pub count: u64,
    pub note: String,
    pub query: Option<String>,
}

#[frb(mirror(RecentDto))]
pub struct _RecentDto {
    pub title: String,
    pub artist: Option<String>,
    pub year: Option<u16>,
    pub tracks: u32,
    pub added_ms: i64,
    pub query: String,
}

#[frb(mirror(RootDto))]
pub struct _RootDto {
    pub id: i64,
    pub path: String,
    pub online: bool,
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
