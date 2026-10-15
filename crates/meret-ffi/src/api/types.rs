//! Mirrors of `meret_api` DTOs, declared here so codegen sees them.

use flutter_rust_bridge::frb;
pub use meret_api::{
    AnchorDto, ColumnDto, FidelityDto, FrontDto, FrontLineDto, HistogramDto, HitDto, HitKind, IdiomLineDto, JobDto,
    NowDto, PersonDto, QueryDto, QueryKind, RecentDto, ReleaseDto, RootDto, RowsDto, SearchDto, SourceDto, StageDto,
    StatusDto, StopDto, TargetDto, ThreadDto, ThreadKind, TrackRowDto, TrailDto, TransportDto,
};
pub use meret_api::LightDto;
pub use meret_api::{FacetColumnDto, FacetDto, FacetsDto, GroupDto, ItemDto, SortKeyDto, ViewDto};
pub use meret_api::{FolderKindDto, FolderSuggestionDto, LightLevelDto, OutputDeviceDto, SettingsDto};

#[frb(mirror(LightLevelDto))]
pub enum _LightLevelDto {
    Off,
    Accent,
    AccentAndWash,
}

#[frb(mirror(SettingsDto))]
pub struct _SettingsDto {
    pub light: LightLevelDto,
    pub output_device: Option<String>,
    pub exclusive: bool,
}

#[frb(mirror(OutputDeviceDto))]
pub struct _OutputDeviceDto {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub can_be_exclusive: bool,
    pub sample_rates: Vec<u32>,
    pub max_bits: u8,
}

#[frb(mirror(FolderKindDto))]
pub enum _FolderKindDto {
    Music,
    Steam,
    AppleMusic,
    Volume,
}

#[frb(mirror(FolderSuggestionDto))]
pub struct _FolderSuggestionDto {
    pub path: String,
    pub label: String,
    pub kind: FolderKindDto,
    pub audio_files: Option<u64>,
    pub more: bool,
    pub note: String,
    pub asks_permission: bool,
}

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

#[frb(mirror(SortKeyDto))]
pub enum _SortKeyDto {
    Library,
    Title,
    Artist,
    Album,
    Year,
    Length,
    Format,
}

#[frb(mirror(ViewDto))]
pub struct _ViewDto {
    pub sort: SortKeyDto,
    pub descending: bool,
    pub group: bool,
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

#[frb(mirror(LightDto))]
pub struct _LightDto {
    pub light: u32,
    pub wash: u32,
    pub dim: u32,
}

#[frb(mirror(NowDto))]
pub struct _NowDto {
    pub track_id: Option<i64>,
    pub release_id: Option<i64>,
    pub cover: Option<String>,
    pub light: Option<LightDto>,
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
    pub key: String,
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
    pub artist_id: Option<i64>,
    pub album: String,
    pub album_artist: Option<String>,
    pub album_artist_id: Option<i64>,
    pub release_id: i64,
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
    pub tracks: u64,
    pub releases: u64,
    pub offset: u64,
    pub items: Vec<ItemDto>,
}

#[frb(mirror(ItemDto))]
pub enum _ItemDto {
    Group(GroupDto),
    Track { ordinal: u32, row: TrackRowDto },
}

#[frb(mirror(GroupDto))]
pub struct _GroupDto {
    pub release_id: i64,
    pub title: String,
    pub album_artist: Option<String>,
    pub album_artist_id: Option<i64>,
    pub year: Option<u16>,
    pub idiom: Option<String>,
    pub tracks: u32,
    pub length_ms: u64,
    pub format: String,
    pub cover: Option<String>,
}

#[frb(mirror(FacetsDto))]
pub struct _FacetsDto {
    pub idioms: FacetColumnDto,
    pub people: FacetColumnDto,
    pub releases: FacetColumnDto,
}

#[frb(mirror(FacetColumnDto))]
pub struct _FacetColumnDto {
    pub all_query: String,
    pub tracks: u32,
    pub entries: Vec<FacetDto>,
}

#[frb(mirror(FacetDto))]
pub struct _FacetDto {
    pub id: i64,
    pub name: String,
    pub tracks: u32,
    pub selected: bool,
    pub query: String,
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
    pub release_id: i64,
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
    pub tracks: u64,
    pub label: String,
}

#[frb(mirror(StopDto))]
pub struct _StopDto {
    pub index: u32,
    pub parent: Option<u32>,
    pub target: TargetDto,
    pub title: String,
    pub via: Option<String>,
    pub via_source: Option<String>,
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

#[frb(mirror(TargetDto))]
pub enum _TargetDto {
    Search { query: String },
    Release { id: i64 },
    Person { id: i64 },
}

#[frb(mirror(ThreadKind))]
pub enum _ThreadKind {
    ComposedBy,
    ArrangedBy,
    LyricsBy,
    SungBy,
    PerformedBy,
    ConductedBy,
    ProducedBy,
    EngineeredBy,
    MemberOf,
    WorkedWith,
    RecordingOf,
    ArrangedAs,
    CoverOf,
    Sampled,
    SameSession,
    Scored,
    Label,
    Cites,
    SoundsLike,
    ListenedAfter,
    By,
    AlbumArtist,
    AppearsOn,
    Matched,
}

#[frb(mirror(ThreadDto))]
pub struct _ThreadDto {
    pub kind: ThreadKind,
    pub label: String,
    pub source: String,
    pub to: TargetDto,
    pub title: String,
    pub detail: String,
}

#[frb(mirror(ReleaseDto))]
pub struct _ReleaseDto {
    pub id: i64,
    pub title: String,
    pub cover: Option<String>,
    pub artist: Option<String>,
    pub year: Option<u16>,
    pub idiom: Option<String>,
    pub tracks: u32,
    pub discs: u32,
    pub length_ms: u64,
    pub formats: Vec<String>,
    pub rows: Vec<TrackRowDto>,
    pub credits: Vec<ThreadDto>,
}

#[frb(mirror(PersonDto))]
pub struct _PersonDto {
    pub id: i64,
    pub name: String,
    pub tracks: u32,
    pub releases: Vec<ThreadDto>,
    pub appears_on: Vec<ThreadDto>,
    pub worked_with: Vec<ThreadDto>,
}
