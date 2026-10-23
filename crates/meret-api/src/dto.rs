//! Plain data for the UI. Flat structs and simple enums, so flutter_rust_bridge
//! (and later a websocket) can carry them without custom codecs.

use std::path::Path;

use meret_core::{Front, NowState, PersonPage, ReleasePage, Search, StatusState};
use meret_core::{Facet, FacetColumn, Facets, GroupRow, SortKey, View};
use meret_graph::Trail;
use meret_model::signal::Fidelity;
use meret_model::thread::source_label;
use meret_model::{AgentId, EntityRef, GameId, Idiom, ReleaseId, WorkId};
use meret_query::{NameField, Term};
use meret_store::TrackRow;

pub use meret_model::ThreadKind;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LightLevelDto {
    Off,
    #[default]
    Accent,
    AccentAndWash,
}

/// Whether Meret may look things up online; asked once.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum LookupsDto {
    #[default]
    Unasked,
    Allowed,
    Off,
}

impl From<meret_core::Lookups> for LookupsDto {
    fn from(l: meret_core::Lookups) -> Self {
        match l {
            meret_core::Lookups::Unasked => Self::Unasked,
            meret_core::Lookups::Allowed => Self::Allowed,
            meret_core::Lookups::Off => Self::Off,
        }
    }
}

impl From<LookupsDto> for meret_core::Lookups {
    fn from(l: LookupsDto) -> Self {
        match l {
            LookupsDto::Unasked => Self::Unasked,
            LookupsDto::Allowed => Self::Allowed,
            LookupsDto::Off => Self::Off,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SettingsDto {
    pub light: LightLevelDto,
    pub output_device: Option<String>,
    pub exclusive: bool,
    pub lookups: LookupsDto,
}

impl From<meret_core::Settings> for SettingsDto {
    fn from(s: meret_core::Settings) -> Self {
        let light = match s.light {
            meret_core::LightLevel::Off => LightLevelDto::Off,
            meret_core::LightLevel::Accent => LightLevelDto::Accent,
            meret_core::LightLevel::AccentAndWash => LightLevelDto::AccentAndWash,
        };
        Self { light, output_device: s.output_device, exclusive: s.exclusive, lookups: s.lookups.into() }
    }
}

impl From<SettingsDto> for meret_core::Settings {
    fn from(s: SettingsDto) -> Self {
        let light = match s.light {
            LightLevelDto::Off => meret_core::LightLevel::Off,
            LightLevelDto::Accent => meret_core::LightLevel::Accent,
            LightLevelDto::AccentAndWash => meret_core::LightLevel::AccentAndWash,
        };
        Self { light, output_device: s.output_device, exclusive: s.exclusive, lookups: s.lookups.into() }
    }
}

/// What MusicBrainz lookups would send and have done: the consent line on
/// the Front and Settings › Lookups.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LookupStatusDto {
    pub setting: LookupsDto,
    /// MusicBrainz IDs in your tags, by kind.
    pub releases: u64,
    pub recordings: u64,
    pub people: u64,
    /// Releases without an ID, to match by album title and artist.
    pub unidentified: u64,
    /// Releases a match by name identified.
    pub matched: u64,
    pub looked_up: u64,
    pub waiting: u64,
    pub failed: u64,
}

impl LookupStatusDto {
    pub fn new(setting: meret_core::Lookups, s: meret_core::LookupSummary) -> Self {
        LookupStatusDto {
            setting: setting.into(),
            releases: s.releases,
            recordings: s.recordings,
            people: s.people,
            unidentified: s.unidentified,
            matched: s.matched,
            looked_up: s.jobs.done,
            waiting: s.jobs.queued + s.jobs.running,
            failed: s.jobs.failed,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutputDeviceDto {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub can_be_exclusive: bool,
    pub sample_rates: Vec<u32>,
    pub max_bits: u8,
}

impl From<meret_engine::output::DeviceInfo> for OutputDeviceDto {
    fn from(d: meret_engine::output::DeviceInfo) -> Self {
        Self { id: d.id, name: d.name, is_default: d.is_default, can_be_exclusive: d.can_be_exclusive,
            sample_rates: d.sample_rates, max_bits: d.max_bits }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct VolumeDto {
    pub scalar: Option<f32>,
    pub settable: bool,
    pub reason: Option<String>,
}

impl From<meret_engine::output::DeviceVolume> for VolumeDto {
    fn from(volume: meret_engine::output::DeviceVolume) -> Self {
        Self { scalar: volume.scalar, settable: volume.settable, reason: volume.reason }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FolderKindDto {
    Music,
    Steam,
    AppleMusic,
    Volume,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FolderSuggestionDto {
    pub path: String,
    pub label: String,
    pub kind: FolderKindDto,
    pub audio_files: Option<u64>,
    pub more: bool,
    pub note: String,
    pub asks_permission: bool,
}

impl From<meret_core::FolderSuggestion> for FolderSuggestionDto {
    fn from(s: meret_core::FolderSuggestion) -> Self {
        let kind = match s.kind {
            meret_core::FolderKind::Music => FolderKindDto::Music,
            meret_core::FolderKind::Steam => FolderKindDto::Steam,
            meret_core::FolderKind::AppleMusic => FolderKindDto::AppleMusic,
            meret_core::FolderKind::Volume => FolderKindDto::Volume,
        };
        Self { path: s.path.to_string_lossy().into_owned(), label: s.label, kind, audio_files: s.audio_files,
            more: s.more, note: s.note, asks_permission: s.asks_permission }
    }
}

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

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SortKeyDto {
    #[default]
    Library,
    Title,
    Artist,
    Album,
    Year,
    Length,
    Format,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ViewDto {
    pub sort: SortKeyDto,
    pub descending: bool,
    pub group: bool,
}

impl From<ViewDto> for View {
    fn from(v: ViewDto) -> Self {
        let sort = match v.sort {
            SortKeyDto::Library => SortKey::Library,
            SortKeyDto::Title => SortKey::Title,
            SortKeyDto::Artist => SortKey::Artist,
            SortKeyDto::Album => SortKey::Album,
            SortKeyDto::Year => SortKey::Year,
            SortKeyDto::Length => SortKey::Length,
            SortKeyDto::Format => SortKey::Format,
        };
        Self { sort, descending: v.descending, group: v.group }
    }
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
    /// The next playable item; at the queue's end, stop.
    Next,
    /// More than three seconds in, the start of this item; otherwise the one before.
    Previous,
    Stop,
    /// Start the current item at zero, including a restored, unloaded queue.
    FromStart,
}

/// One queued item after the playing one, as Now's Up next lists it.
#[derive(Clone, Debug, PartialEq)]
pub struct UpNextItemDto {
    pub token: u64,
    pub track_id: Option<i64>,
    pub title: String,
    /// "Joanne Hogg · Xenogears": the credit and the release, when known.
    pub subtitle: String,
    pub length_ms: Option<u64>,
    /// Why it was queued, when the core can say: "from this trail".
    pub why: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct UpNextDto {
    pub items: Vec<UpNextItemDto>,
    /// How many items follow the playing one in all, listed or not.
    pub remaining: u64,
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

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LightDto {
    pub light: u32,
    pub wash: u32,
    pub dim: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct NowDto {
    pub track_id: Option<i64>,
    pub release_id: Option<i64>,
    pub cover: Option<String>,
    pub light: Option<LightDto>,
    pub title: String,
    pub subtitle: String,
    /// Why this is playing, when something chose it: "Dormant · 2 years: 96 plays, then nothing".
    pub why: Option<String>,
    pub anchor: Option<AnchorDto>,
    pub length_ms: Option<u64>,
    pub path: Vec<StageDto>,
    pub fidelity: Option<FidelityDto>,
    pub error: Option<String>,
}

impl NowDto {
    pub fn from_state(n: &NowState, art_dir: &Path) -> Self {
        let now = meret_engine::clock::now_ns();
        NowDto {
            track_id: n.track.map(|t| t.0),
            release_id: n.release.map(|r| r.0),
            cover: n.cover.as_ref().map(|a| meret_store::cover_file(art_dir, &a.hash, 256).to_string_lossy().into_owned()),
            light: n.cover.as_ref().and_then(|a| Some(LightDto { light: a.light?, wash: a.light_wash?, dim: a.light_dim? })),
            title: n.title.clone(),
            subtitle: n.subtitle.clone(),
            why: n.why.clone(),
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
    pub key: String,
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
    /// Changes when lookups add facts; release, person and work panes refetch.
    pub lookups_version: u64,
}

impl From<&StatusState> for StatusDto {
    fn from(s: &StatusState) -> Self {
        StatusDto {
            sources: s.sources.iter().map(|x| SourceDto { key: x.key.clone(), name: x.name.clone(), detail: x.detail.clone(), ok: x.ok }).collect(),
            jobs: s.jobs.iter().map(|j| JobDto { verb: j.verb.clone(), done: j.done, total: j.total }).collect(),
            guessed: s.guessed,
            new_leads: s.new_leads,
            tracks: s.tracks,
            library_version: s.library_version,
            lookups_version: s.lookups_version,
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
    pub tracks: u64,
    pub releases: u64,
    pub offset: u64,
    pub items: Vec<ItemDto>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum ItemDto {
    Group(GroupDto),
    Track { ordinal: u32, row: TrackRowDto },
}

#[derive(Clone, Debug, PartialEq)]
pub struct GroupDto {
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

impl GroupDto {
    pub(crate) fn from_group(g: GroupRow, art_dir: &Path) -> Self {
        let (album_artist_id, album_artist) = match g.album_artist {
            Some((id, name)) => (Some(id.0), Some(name)),
            None => (None, None),
        };
        Self {
            release_id: g.release.0,
            title: g.title,
            album_artist,
            album_artist_id,
            year: g.year,
            idiom: g.idiom.map(|i| i.as_str().into()),
            tracks: g.tracks,
            length_ms: g.length_ms,
            format: g.formats.join(" · "),
            cover: g.cover.map(|a| meret_store::cover_file(art_dir, &a.hash, 64).to_string_lossy().into_owned()),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FacetsDto {
    pub idioms: FacetColumnDto,
    pub people: FacetColumnDto,
    pub releases: FacetColumnDto,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FacetColumnDto {
    pub all_query: String,
    pub tracks: u32,
    pub entries: Vec<FacetDto>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FacetDto {
    pub id: i64,
    pub name: String,
    pub tracks: u32,
    pub selected: bool,
    pub query: String,
}

impl From<Facets> for FacetsDto {
    fn from(f: Facets) -> Self {
        Self { idioms: f.idioms.into(), people: f.people.into(), releases: f.releases.into() }
    }
}

impl From<FacetColumn> for FacetColumnDto {
    fn from(c: FacetColumn) -> Self {
        Self { all_query: c.all_query, tracks: c.tracks, entries: c.entries.into_iter().map(Into::into).collect() }
    }
}

impl From<Facet> for FacetDto {
    fn from(f: Facet) -> Self {
        Self { id: f.id, name: f.name, tracks: f.tracks, selected: f.selected, query: f.query }
    }
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
    /// The MusicBrainz question, in Needs you while it's unanswered and the
    /// tags carry an ID to look up.
    pub lookups: Option<LookupStatusDto>,
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
    pub tracks: u64,
    pub label: String,
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

        let line = |label: &str, count, note: &str, query: Option<&str>| FrontLineDto {
            label: label.into(),
            count,
            note: note.into(),
            query: query.map(Into::into),
        };
        let mut formats: Vec<_> = f.formats.into_iter()
            .map(|f| line(f.label, f.count, f.note, f.query))
            .collect();
        formats.retain(|l| l.count > 0);
        formats.sort_by_key(|l| std::cmp::Reverse(l.count));

        let offline = f.roots.iter().filter(|r| !r.online).count() as u64;
        let mut needs_you = vec![
            line("Unreadable files", f.facts.unreadable, "", None),
            line("No artist tag", f.facts.no_artist, "", None),
            line("Missing files", f.facts.missing, "", None),
            line("Offline folders", offline, "", None),
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
                .map(|r| RootDto { id: r.id.0, path: r.path.display().to_string(), online: r.online, tracks: r.tracks, label: r.label })
                .collect(),
            lookups: None,
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
    Work { id: i64 },
    Game { id: i64 },
}

impl TargetDto {
    /// The trail stop, and the root query a search carries.
    pub fn entity(&self) -> (EntityRef, Option<String>) {
        match self {
            TargetDto::Search { query } => (EntityRef::Search, Some(query.clone())),
            TargetDto::Release { id } => (EntityRef::Release(ReleaseId(*id)), None),
            TargetDto::Person { id } => (EntityRef::Agent(AgentId(*id)), None),
            TargetDto::Work { id } => (EntityRef::Work(WorkId(*id)), None),
            TargetDto::Game { id } => (EntityRef::Game(GameId(*id)), None),
        }
    }

    fn of(e: EntityRef, root_query: Option<&str>) -> Self {
        match e {
            EntityRef::Search => TargetDto::Search { query: root_query.unwrap_or_default().into() },
            EntityRef::Release(r) => TargetDto::Release { id: r.0 },
            EntityRef::Agent(a) => TargetDto::Person { id: a.0 },
            EntityRef::Work(w) => TargetDto::Work { id: w.0 },
            EntityRef::Game(g) => TargetDto::Game { id: g.0 },
            // Only `Api` writes the trail, and it only opens these five.
            other => unreachable!("{other:?} is not a pane yet"),
        }
    }
}

/// The thread a credit role draws to a person, and how a person pane heads
/// the releases they have in that role.
pub(crate) fn role_thread(role: &str) -> Option<(ThreadKind, &'static str)> {
    Some(match role {
        "composer" => (ThreadKind::ComposedBy, "Composed"),
        "lyricist" => (ThreadKind::LyricsBy, "Lyrics"),
        "arranger" => (ThreadKind::ArrangedBy, "Arranged"),
        "performer" => (ThreadKind::PerformedBy, "Performed"),
        "conductor" => (ThreadKind::ConductedBy, "Conducted"),
        "producer" => (ThreadKind::ProducedBy, "Produced"),
        "engineer" => (ThreadKind::EngineeredBy, "Engineered"),
        _ => return None,
    })
}

/// A thread out of a pane. Following it opens `to` to the right.
#[derive(Clone, Debug, PartialEq)]
pub struct ThreadDto {
    pub kind: ThreadKind,
    /// "by", "album artist", "on", "worked with".
    pub label: String,
    /// "tags", "MB", "your library".
    pub source: String,
    /// The source's key, handed back to `follow`: "local_tags", "musicbrainz".
    pub provider: String,
    pub to: TargetDto,
    pub title: String,
    /// "1-03, 1-07"; "2010 · 12 tracks"; "3 releases".
    pub detail: String,
}

impl ThreadDto {
    fn local(kind: ThreadKind, to: TargetDto, title: String, detail: String) -> Self {
        Self::from_source(kind, LOCAL_TAGS, to, title, detail)
    }

    fn from_source(kind: ThreadKind, provider: &str, to: TargetDto, title: String, detail: String) -> Self {
        ThreadDto { kind, label: kind.label().into(), source: source_label(provider).into(), provider: provider.into(), to, title, detail }
    }
}

/// Threads read from file tags.
pub(crate) const LOCAL_TAGS: &str = "local_tags";
/// Threads from MusicBrainz lookups.
pub(crate) const MUSICBRAINZ: &str = "musicbrainz";
/// Games from Wikidata.
pub(crate) const WIKIDATA: &str = "wikidata";

/// A thread to a game, with its year.
fn game_thread(kind: ThreadKind, g: meret_core::GameLink) -> ThreadDto {
    ThreadDto::from_source(kind, &g.source, TargetDto::Game { id: g.game.0 }, g.title, g.year.map(|y| y.to_string()).unwrap_or_default())
}

/// A release pane (plate 01, the middle pane).
#[derive(Clone, Debug, PartialEq)]
pub struct ReleaseDto {
    pub id: i64,
    pub title: String,
    pub cover: Option<String>,
    /// The album artist.
    pub artist: Option<String>,
    /// Individual album-artist thread targets; `artist` keeps the written credit.
    pub artist_links: Vec<ThreadDto>,
    pub year: Option<u16>,
    /// "Score", "Album"; None when not sorted yet.
    pub idiom: Option<String>,
    pub tracks: u32,
    pub discs: u32,
    pub length_ms: u64,
    /// Best-copy formats, then other copies: "FLAC 16/44.1", "also MP3".
    pub formats: Vec<String>,
    /// The tracklist; row i plays with `play_release(id, i)`.
    pub rows: Vec<TrackRowDto>,
    /// The work each row is a recording of, where its tags say.
    pub row_works: Vec<Option<ThreadDto>>,
    /// The album artist, each track artist and where they are, then
    /// composers, arrangers, performers and the other roles.
    pub credits: Vec<ThreadDto>,
    /// The game it's the soundtrack of.
    pub games: Vec<ThreadDto>,
    /// Counted plays of this release, and the newest one (Unix ms).
    pub plays: u64,
    pub last_played_ms: Option<i64>,
}

impl ReleaseDto {
    pub fn from_page(p: ReleasePage, art_dir: &Path) -> Self {
        let best_codecs: Vec<&str> = p.tracks.iter().filter_map(|r| r.codec.as_deref()).collect();
        let mut other_formats: Vec<String> = p.tracks.iter().flat_map(|r| r.other_formats.iter())
            .filter(|codec| !best_codecs.iter().any(|best| best.eq_ignore_ascii_case(codec)))
            .cloned().collect();
        other_formats.sort();
        other_formats.dedup();
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

        let artist_links: Vec<_> = p.album_artists.iter().map(|(agent, name)| {
            ThreadDto::local(ThreadKind::AlbumArtist, TargetDto::Person { id: agent.0 }, name.clone(), String::new())
        }).collect();
        let mut credits = artist_links.clone();
        let positions = |positions: &[(u32, u32)]| {
            if positions.len() == rows.len() {
                format!("all {} tracks", rows.len())
            } else if positions.len() > 6 {
                format!("{} tracks", positions.len())
            } else {
                let multi = discs.len() > 1;
                positions.iter().map(|&(d, n)| if multi { format!("{d}-{n:02}") } else { n.to_string() }).collect::<Vec<_>>().join(", ")
            }
        };
        for a in p.artists {
            // The album artist on every track is already said.
            if a.positions.len() == rows.len() && p.album_artists.iter().any(|(id, _)| *id == a.agent) {
                continue;
            }
            let detail = positions(&a.positions);
            credits.push(ThreadDto::local(ThreadKind::By, TargetDto::Person { id: a.agent.0 }, a.name, detail));
        }
        for c in p.roles {
            let Some((kind, _)) = role_thread(&c.role) else { continue };
            // A soundtrack's composer is often its artist on the same tracks; one line says it.
            if credits.iter().any(|t| t.kind == ThreadKind::By && t.to == (TargetDto::Person { id: c.agent.0 }) && t.detail == positions(&c.positions)) {
                continue;
            }
            let detail = match c.detail {
                Some(plays) => format!("{plays} · {}", positions(&c.positions)),
                None => positions(&c.positions),
            };
            credits.push(ThreadDto::from_source(kind, &c.source, TargetDto::Person { id: c.agent.0 }, c.name, detail));
        }
        let row_works = rows.iter().map(|row| {
            p.works.iter().find(|(track, _, _)| track.0 == row.track_id).map(|(_, work, title)| {
                ThreadDto::local(ThreadKind::RecordingOf, TargetDto::Work { id: work.0 }, title.clone(), String::new())
            })
        }).collect();
        ReleaseDto {
            id: p.release.0,
            title: p.title,
            cover: p.cover.as_ref().map(|a| meret_store::cover_file(art_dir, &a.hash, 256).to_string_lossy().into_owned()),
            artist: p.album_artist.map(|(_, name)| name),
            artist_links,
            year: p.year,
            idiom: p.idiom.map(|i| singular(i).into()),
            tracks: rows.len() as u32,
            discs: discs.len() as u32,
            length_ms: rows.iter().filter_map(|r| r.length_ms).sum(),
            formats: formats.into_iter().map(|(f, _)| f)
                .chain((!other_formats.is_empty()).then(|| format!("also {}", other_formats.join(", ")))).collect(),
            rows,
            row_works,
            credits,
            games: p.games.into_iter().map(|g| game_thread(ThreadKind::SoundtrackOf, g)).collect(),
            plays: p.plays,
            last_played_ms: p.last_played,
        }
    }
}

/// A person pane (plate 01, the first pane). Groups are people here too.
#[derive(Clone, Debug, PartialEq)]
pub struct PersonDto {
    pub id: i64,
    pub name: String,
    /// Every track they're on, in any role.
    pub tracks: u32,
    /// Releases they're the album artist of, by year.
    pub releases: Vec<ThreadDto>,
    /// Other people's releases they're on, by year.
    pub appears_on: Vec<ThreadDto>,
    /// Releases they're credited on in other roles: "Composed", "Arranged",
    /// "Performed"…, each by year.
    pub roles: Vec<CreditSectionDto>,
    /// Works they wrote, by title.
    pub works: Vec<ThreadDto>,
    /// "Member of" and "Members", from MusicBrainz.
    pub groups: Vec<CreditSectionDto>,
    /// Games they scored.
    pub games: Vec<ThreadDto>,
    /// People who share releases with them, most shared first, then the
    /// collaborations MusicBrainz knows of.
    pub worked_with: Vec<ThreadDto>,
    /// Counted plays of their recordings and the releases they front.
    pub plays: u64,
    pub last_played_ms: Option<i64>,
}

/// A headed list of threads on a pane.
#[derive(Clone, Debug, PartialEq)]
pub struct CreditSectionDto {
    pub title: String,
    pub threads: Vec<ThreadDto>,
}

impl From<PersonPage> for PersonDto {
    fn from(p: PersonPage) -> Self {
        let n = |n: u32, one: &str, many: &str| format!("{n} {}", if n == 1 { one } else { many });
        let release = |r: meret_core::PersonRelease, kind: ThreadKind, own: bool| {
            let count = if own { n(r.tracks, "track", "tracks") } else { format!("{} of {}", r.theirs, n(r.tracks, "track", "tracks")) };
            let detail = r.year.map(|y| format!("{y} · {count}")).unwrap_or(count);
            ThreadDto::local(kind, TargetDto::Release { id: r.release.0 }, r.title, detail)
        };
        PersonDto {
            id: p.agent.0,
            name: p.name,
            tracks: p.tracks,
            plays: p.plays,
            last_played_ms: p.last_played,
            releases: p.releases.into_iter().map(|r| release(r, ThreadKind::AppearsOn, true)).collect(),
            appears_on: p.appears_on.into_iter().map(|r| release(r, ThreadKind::AppearsOn, false)).collect(),
            roles: p.roles.into_iter().filter_map(|(role, releases)| {
                let (kind, title) = role_thread(&role)?;
                Some(CreditSectionDto { title: title.into(), threads: releases.into_iter().map(|r| release(r, kind, false)).collect() })
            }).collect(),
            works: p.works.into_iter().map(|w| {
                ThreadDto::local(ThreadKind::ComposedBy, TargetDto::Work { id: w.work.0 }, w.title, n(w.tracks, "track", "tracks"))
            }).collect(),
            groups: [("Member of", ThreadKind::MemberOf, p.member_of), ("Members", ThreadKind::HasMember, p.members)]
                .into_iter()
                .filter(|(_, _, links)| !links.is_empty())
                .map(|(title, kind, links)| CreditSectionDto {
                    title: title.into(),
                    threads: links.into_iter().map(|l| link(kind, l)).collect(),
                })
                .collect(),
            games: p.games.into_iter().map(|g| game_thread(ThreadKind::Scored, g)).collect(),
            worked_with: p
                .worked_with
                .iter()
                .map(|c| {
                    let detail = n(c.releases, "release", "releases");
                    ThreadDto::local(ThreadKind::WorkedWith, TargetDto::Person { id: c.agent.0 }, c.name.clone(), detail)
                })
                .chain(p.linked.into_iter()
                    .filter(|l| !p.worked_with.iter().any(|c| c.agent == l.agent))
                    .map(|l| link(ThreadKind::WorkedWith, l)))
                .collect(),
        }
    }
}

/// A person MusicBrainz relates to this one: what they did, and their tracks here.
fn link(kind: ThreadKind, l: meret_core::PersonLink) -> ThreadDto {
    let tracks = (l.tracks > 0).then(|| format!("{} {}", l.tracks, if l.tracks == 1 { "track" } else { "tracks" }));
    let detail = [l.detail, tracks].into_iter().flatten().collect::<Vec<_>>().join(" · ");
    ThreadDto::from_source(kind, &l.source, TargetDto::Person { id: l.agent.0 }, l.name, detail)
}

/// A work pane: a composition, its composer, its parts, and every
/// recording of it in the library.
#[derive(Clone, Debug, PartialEq)]
pub struct WorkDto {
    pub id: i64,
    pub title: String,
    /// The composer as written.
    pub composer: Option<String>,
    /// Each composer as a thread target; `composer` keeps the written credit.
    pub composer_links: Vec<ThreadDto>,
    /// The work this is a movement or part of.
    pub part_of: Option<ThreadDto>,
    /// Its movements or parts, in order.
    pub parts: Vec<ThreadDto>,
    /// Recordings of it and its parts; row i plays with `play_work(id, i)`.
    pub rows: Vec<TrackRowDto>,
    /// Recordings MusicBrainz knows that you don't have, each to its first artist.
    pub others: Vec<ThreadDto>,
    /// How many recordings MusicBrainz knows of it, when looked up.
    pub recordings_known: Option<u64>,
    pub length_ms: u64,
    pub plays: u64,
    pub last_played_ms: Option<i64>,
}

impl From<meret_core::WorkPage> for WorkDto {
    fn from(p: meret_core::WorkPage) -> Self {
        let n = |n: u32| format!("{n} {}", if n == 1 { "track" } else { "tracks" });
        let rows: Vec<TrackRowDto> = p.tracks.into_iter().map(TrackRowDto::from).collect();
        WorkDto {
            id: p.work.0,
            title: p.title,
            composer: p.composer,
            composer_links: p.composers.into_iter().map(|(agent, name)| {
                ThreadDto::local(ThreadKind::ComposedBy, TargetDto::Person { id: agent.0 }, name, String::new())
            }).collect(),
            part_of: p.parent.map(|(work, title)| ThreadDto::local(ThreadKind::RecordingOf, TargetDto::Work { id: work.0 }, title, String::new())),
            parts: p.parts.into_iter().map(|w| {
                ThreadDto::local(ThreadKind::RecordingOf, TargetDto::Work { id: w.work.0 }, w.title, n(w.tracks))
            }).collect(),
            length_ms: rows.iter().filter_map(|r| r.length_ms).sum(),
            rows,
            others: p.others.into_iter().filter_map(|o| {
                let (first, _) = *o.artists.first()?;
                let names = o.artists.iter().map(|(_, name)| name.as_str()).collect::<Vec<_>>().join(", ");
                let length = o.length_ms.map(|ms| format!("{}:{:02}", ms / 60_000, ms / 1_000 % 60));
                let detail = [Some(names), length].into_iter().flatten().collect::<Vec<_>>().join(" · ");
                Some(ThreadDto::from_source(ThreadKind::By, &o.source, TargetDto::Person { id: first.0 }, o.title, detail))
            }).collect(),
            recordings_known: p.recordings_known,
            plays: p.plays,
            last_played_ms: p.last_played,
        }
    }
}

/// A game pane: the game a score belongs to, its composers, and the
/// soundtracks of it you have.
#[derive(Clone, Debug, PartialEq)]
pub struct GameDto {
    pub id: i64,
    pub title: String,
    pub year: Option<u16>,
    /// "Acquire, FromSoftware".
    pub developers: Option<String>,
    /// "PlayStation, Microsoft Windows".
    pub platforms: Option<String>,
    pub series: Option<String>,
    pub composers: Vec<ThreadDto>,
    pub soundtracks: Vec<ThreadDto>,
    /// Other games in its series you have a soundtrack of.
    pub same_series: Vec<ThreadDto>,
    /// Its soundtracks' tracks; row i plays with `play_game(id, i)`.
    pub rows: Vec<TrackRowDto>,
    pub length_ms: u64,
    pub plays: u64,
    pub last_played_ms: Option<i64>,
}

impl From<meret_core::GamePage> for GameDto {
    fn from(p: meret_core::GamePage) -> Self {
        let rows: Vec<TrackRowDto> = p.tracks.into_iter().map(TrackRowDto::from).collect();
        GameDto {
            id: p.game.0,
            title: p.title,
            year: p.year,
            developers: p.developers,
            platforms: p.platforms,
            series: p.series,
            composers: p.composers.into_iter().map(|l| link(ThreadKind::ComposedBy, l)).collect(),
            soundtracks: p.soundtracks.into_iter().map(|r| {
                let tracks = format!("{} {}", r.tracks, if r.tracks == 1 { "track" } else { "tracks" });
                let detail = r.year.map(|y| format!("{y} · {tracks}")).unwrap_or(tracks);
                ThreadDto::local(ThreadKind::Soundtrack, TargetDto::Release { id: r.release.0 }, r.title, detail)
            }).collect(),
            same_series: p.same_series.into_iter().map(|g| game_thread(ThreadKind::SameSeries, g)).collect(),
            length_ms: rows.iter().filter_map(|r| r.length_ms).sum(),
            rows,
            plays: p.plays,
            last_played_ms: p.last_played,
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

/// A branch of the tree, peeks folded away: the run of stops from the one
/// after its fork to its leaf. "Forks here" lists those leaving a pane.
#[derive(Clone, Debug, PartialEq)]
pub struct BranchDto {
    /// The stop it leaves from; None for the trunk from the root.
    pub fork: Option<u32>,
    /// Its first stop, the one the fork's thread led to.
    pub first: u32,
    pub leaf: u32,
    pub stops: u32,
    /// When its leaf was last open.
    pub when_ms: i64,
    /// What was done on it, in order, once each: "played", "wanted".
    pub actions: Vec<String>,
    /// It holds the current stop.
    pub current: bool,
    /// Nothing done on it and not current, so `prune_branch` hides it.
    pub prunable: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TrailDto {
    pub root_query: Option<String>,
    pub current: u32,
    pub stops: Vec<StopDto>,
    pub meetings: Vec<(u32, u32)>,
    /// The current branch first, then newest first.
    pub branches: Vec<BranchDto>,
    pub kept: bool,
    pub name: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct TrailSummaryDto {
    pub uid: String,
    pub title: String,
    pub stops: u32,
    pub branches: u32,
    pub when_ms: i64,
    pub kept: bool,
    pub name: Option<String>,
    pub played: u32,
    pub wanted: u32,
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
        let branches = t
            .branches(now)
            .into_iter()
            .map(|b| {
                let mut actions: Vec<String> = vec![];
                for &s in &b.stops {
                    for action in &t.stop(s).actions {
                        let name = action_name(*action);
                        if !actions.iter().any(|a| a == name) {
                            actions.push(name.into());
                        }
                    }
                }
                let current = b.stops.contains(&t.current());
                BranchDto {
                    fork: b.fork.map(|f| f as u32),
                    first: b.stops[0] as u32,
                    leaf: b.leaf as u32,
                    stops: b.stops.len() as u32,
                    when_ms: t.stop(b.leaf).opened_at,
                    prunable: !b.has_actions && !current,
                    current,
                    actions,
                }
            })
            .collect();
        TrailDto {
            root_query: t.root_query.clone(),
            current: t.current() as u32,
            stops,
            meetings: t.meetings().into_iter().map(|(a, b)| (a as u32, b as u32)).collect(),
            branches,
            kept: t.kept,
            name: t.name.clone(),
        }
    }
}

fn action_name(action: meret_graph::Action) -> &'static str {
    match action {
        meret_graph::Action::Played => "played",
        meret_graph::Action::Wanted => "wanted",
        meret_graph::Action::Crated => "crated",
        meret_graph::Action::Noted => "noted",
    }
}

/// Every attempt to hear a recording, including a short skip.
#[derive(Clone, Debug, PartialEq)]
pub struct ListenDto {
    pub uid: String,
    pub track_id: Option<i64>,
    pub recording_id: i64,
    pub release_id: Option<i64>,
    pub title: String,
    pub credit: Option<String>,
    pub release_title: Option<String>,
    pub cover: Option<String>,
    pub started_at_ms: i64,
    pub played_ms: u64,
    pub length_ms: Option<u64>,
    pub counted: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PlayedDto {
    pub track_id: i64,
    pub recording_id: i64,
    pub release_id: i64,
    pub title: String,
    pub credit: Option<String>,
    pub release_title: String,
    pub cover: Option<String>,
    pub plays: u64,
    pub last_played_ms: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DormantDto {
    pub release_id: i64,
    pub title: String,
    pub credit: Option<String>,
    pub cover: Option<String>,
    pub plays: u64,
    pub last_played_ms: i64,
}

impl ListenDto {
    pub(crate) fn from_listen(r: meret_store::ListenRow, art_dir: &Path) -> Self {
        Self {
            uid: r.uid, track_id: r.track.map(|id| id.0), recording_id: r.recording.0,
            release_id: r.release.map(|id| id.0), title: r.title, credit: r.credit,
            release_title: r.release_title, cover: memory_cover(r.cover, art_dir),
            started_at_ms: r.started_at, played_ms: r.played_ms, length_ms: r.length_ms, counted: r.counted,
        }
    }
}

impl PlayedDto {
    pub(crate) fn from_played(r: meret_store::PlayCount, art_dir: &Path) -> Self {
        Self {
            track_id: r.track.0, recording_id: r.recording.0, release_id: r.release.0,
            title: r.title, credit: r.credit, release_title: r.release_title,
            cover: memory_cover(r.cover, art_dir), plays: r.plays, last_played_ms: r.last_played,
        }
    }
}

impl DormantDto {
    pub(crate) fn from_dormant(r: meret_store::Dormant, art_dir: &Path) -> Self {
        Self {
            release_id: r.release.0, title: r.title, credit: r.credit,
            cover: memory_cover(r.cover, art_dir), plays: r.plays, last_played_ms: r.last_played,
        }
    }
}

/// A Play something pick (plate 09): what, and why, in the core's words.
#[derive(Clone, Debug, PartialEq)]
pub struct PickDto {
    pub release_id: i64,
    pub title: String,
    pub credit: Option<String>,
    pub cover: Option<String>,
    /// "Dormant · 2 years", "From your latest trail", "Never played".
    pub label: String,
    /// "96 plays, then nothing for 2 years."
    pub reason: String,
    /// How it will play: "The whole score, in order."
    pub plan: String,
    /// "17 tracks · 1 h 12 · AAC"
    pub meta: String,
}

impl PickDto {
    pub fn new(pick: meret_core::Pick, release: ReleaseDto, now_ms: i64) -> Self {
        let (label, reason) = match pick.why {
            meret_core::Why::Dormant { plays, last_played_ms } => (
                format!("Dormant · {}", ago(now_ms - last_played_ms)),
                format!("{plays} plays, then nothing for {}.", ago(now_ms - last_played_ms)),
            ),
            meret_core::Why::FromTrail { trail, latest } => (
                if latest { "From your latest trail" } else { "From a recent trail" }.into(),
                if trail == release.title { "You opened it, then left without playing it through.".to_owned() }
                else { format!("You reached it on {trail} and haven't played it through.") },
            ),
            meret_core::Why::NeverPlayed { added_ms } => (
                "Never played".into(),
                match added_ms.filter(|ms| *ms > 0) {
                    Some(ms) => format!("In your library for {}, never played through.", ago(now_ms - ms)),
                    None => "In your library, never played through.".into(),
                },
            ),
        };
        let plan = match release.idiom.as_deref() {
            Some("Score") => "The whole score, in order.",
            Some("Session") => "The whole date, in order.",
            Some("Work") => "The whole work, movement by movement.",
            Some("Set") => "The whole set, uncut.",
            Some("Spoken") => "From the first episode.",
            Some("Song") => "The songs, in order.",
            _ => "The whole album, in order.",
        }.into();
        let mut meta = vec![format!("{} {}", release.tracks, if release.tracks == 1 { "track" } else { "tracks" }), listening(release.length_ms)];
        if let Some(format) = release.formats.first() {
            meta.push(format.clone());
        }
        Self {
            release_id: release.id, title: release.title, credit: release.artist, cover: release.cover,
            label, reason, plan, meta: meta.join(" · "),
        }
    }

    /// The line Now shows while the pick plays.
    pub fn why(&self) -> String {
        format!("{} · {}", self.label, self.reason.trim_end_matches('.'))
    }
}

/// How long ago, in words: "2 years", "7 months", "3 weeks", "5 days", "today".
fn ago(elapsed_ms: i64) -> String {
    let days = elapsed_ms.max(0) / 86_400_000;
    let unit = |n: i64, word: &str| format!("{n} {word}{}", if n == 1 { "" } else { "s" });
    if days >= 365 { unit(days / 365, "year") }
    else if days >= 30 { unit(days / 30, "month") }
    else if days >= 7 { unit(days / 7, "week") }
    else if days >= 1 { unit(days, "day") }
    else { "today".into() }
}

/// Listening time as people say it: "1 h 12", "48 min", "under a minute".
fn listening(ms: u64) -> String {
    let minutes = ms / 60_000;
    if minutes >= 60 { if minutes.is_multiple_of(60) { format!("{} h", minutes / 60) } else { format!("{} h {:02}", minutes / 60, minutes % 60) } }
    else if minutes >= 1 { format!("{minutes} min") }
    else { "under a minute".into() }
}

/// A zone Play on lists, with what it does to the sound.
#[derive(Clone, Debug, PartialEq)]
pub struct ZoneDto {
    pub id: String,
    /// "RME ADI-2 DAC", "MacBook Pro Speakers".
    pub name: String,
    /// "This Mac · default output"
    pub detail: String,
    /// "● bit-perfect", "◐ shared with macOS", "◐ refuses above 48 kHz".
    pub verdict: String,
    /// The verdict is a caveat, drawn in the warning colour.
    pub warn: bool,
    pub current: bool,
}

impl From<meret_core::ZoneRow> for ZoneDto {
    fn from(z: meret_core::ZoneRow) -> Self {
        use meret_player::ZoneFidelity as F;
        let khz = |hz: u32| if hz.is_multiple_of(1000) { format!("{} kHz", hz / 1000) } else { format!("{:.1} kHz", hz as f64 / 1000.0) };
        let (verdict, warn) = match z.info.fidelity {
            F::BitPerfect => ("● bit-perfect".to_owned(), false),
            F::BitPerfectVia { system } => (format!("● bit-perfect via {system}"), false),
            F::RefusesAbove { hz } => (format!("◐ refuses above {}", khz(hz)), true),
            F::Shared => ("◐ shared with macOS".to_owned(), true),
            F::ResampledAbove { hz } => (format!("◐ above {} resampled", khz(hz)), true),
            F::Fixed { description, delay_ms } => (format!("◐ {description} · ~{} s delay", delay_ms.div_ceil(1000)), true),
            F::Lossy => ("○ lossy".to_owned(), true),
            F::OwnCopy => ("○ plays its own copy".to_owned(), true),
        };
        Self { id: z.info.id, name: z.info.name, detail: z.info.detail, verdict, warn, current: z.current }
    }
}

fn memory_cover(hash: Option<String>, art_dir: &Path) -> Option<String> {
    hash.map(|hash| meret_store::cover_file(art_dir, &hash, 64).to_string_lossy().into_owned())
}

#[cfg(test)]
mod cover_tests {
    use super::*;
    use meret_model::TrackId;
    use meret_store::Artwork;

    fn art(light: Option<u32>) -> Artwork {
        Artwork {
            hash: "abcd".into(),
            light,
            light_wash: light.map(|c| (c & 0xffffff) | 0x14000000),
            light_dim: light.map(|c| (c & 0xffffff) | 0x55000000),
        }
    }

    #[test]
    fn now_carries_identity_cover_and_light() {
        let state = NowState {
            track: Some(TrackId(7)),
            release: Some(ReleaseId(9)),
            cover: Some(art(Some(0xffcc8844))),
            ..Default::default()
        };
        let now = NowDto::from_state(&state, Path::new("/tmp/meret/art"));
        assert_eq!((now.track_id, now.release_id), (Some(7), Some(9)));
        assert_eq!(now.cover.as_deref(), Some("/tmp/meret/art/abcd-256.jpg"));
        assert_eq!(now.light, Some(LightDto { light: 0xffcc8844, wash: 0x14cc8844, dim: 0x55cc8844 }));
        let pale = NowDto::from_state(&NowState { cover: Some(art(None)), ..Default::default() }, Path::new("/tmp/art"));
        assert!(pale.cover.is_some());
        assert_eq!(pale.light, None);
        let loose = NowDto::from_state(&NowState::default(), Path::new("/tmp/art"));
        assert_eq!((loose.track_id, loose.release_id, loose.cover, loose.light), (None, None, None, None));
    }

    #[test]
    fn release_carries_the_medium_cover_path() {
        let page = ReleasePage {
            release: ReleaseId(9),
            title: "The cover".into(),
            year: None,
            idiom: None,
            album_artist: None,
            album_artists: vec![],
            cover: Some(art(None)),
            tracks: vec![],
            artists: vec![],
            roles: vec![],
            works: vec![],
            games: vec![],
            plays: 0,
            last_played: None,
        };
        let release = ReleaseDto::from_page(page, Path::new("/tmp/meret/art"));
        assert_eq!(release.cover.as_deref(), Some("/tmp/meret/art/abcd-256.jpg"));
    }

    #[test]
    fn release_formats_distinguish_best_copy_from_alternates_without_extra_rows() {
        let track = TrackRow {
            track: TrackId(1), recording: meret_model::RecordingId(1), release: ReleaseId(9),
            idiom: None, title: "Terratus".into(), artist: None, artist_id: None, album: "Tyranny".into(),
            album_artist: None, album_artist_id: None, disc: 1, number: 1, year: None, length_ms: Some(10000),
            codec: Some("FLAC".into()), sample_rate: Some(44100), bits: Some(16),
            other_formats: vec!["MP3".into()], path: Some("/music/1.flac".into()),
        };
        let page = ReleasePage {
            release: ReleaseId(9), title: "Tyranny".into(), year: None, idiom: None,
            album_artist: None, album_artists: vec![], cover: None, tracks: vec![track], artists: vec![], roles: vec![], works: vec![], games: vec![],
            plays: 0, last_played: None,
        };
        let dto = ReleaseDto::from_page(page, Path::new("/tmp/art"));
        assert_eq!(dto.formats, ["FLAC 16/44.1", "also MP3"]);
        assert_eq!((dto.tracks, dto.rows.len(), dto.length_ms), (1, 1, 10000));
        assert_eq!(dto.rows[0].format, "FLAC 16/44.1", "table rows describe the copy playback chooses");
    }
}

#[cfg(test)]
mod view_tests {
    use super::*;

    #[test]
    fn group_carries_small_cover_and_joined_format_labels() {
        let mut group = GroupRow {
            release: ReleaseId(1),
            title: "First Score".into(),
            year: Some(2000),
            idiom: Some(Idiom::Score),
            album_artist: Some((AgentId(2), "Mark Cromer".into())),
            tracks: 3,
            length_ms: 120000,
            formats: vec!["Lossless, up to 16/48", "Hi-res"],
            cover: Some(meret_store::Artwork { hash: "abcd".into(), light: None, light_wash: None, light_dim: None }),
        };
        let dto = GroupDto::from_group(group.clone(), Path::new("/tmp/meret/art"));
        assert_eq!(dto.cover.as_deref(), Some("/tmp/meret/art/abcd-64.jpg"));
        assert_eq!(dto.album_artist_id, Some(2));
        assert_eq!(dto.album_artist.as_deref(), Some("Mark Cromer"));
        assert_eq!(dto.idiom.as_deref(), Some("score"));
        assert_eq!(dto.format, "Lossless, up to 16/48 · Hi-res");
        group.cover = None;
        assert!(GroupDto::from_group(group, Path::new("/tmp/meret/art")).cover.is_none());
        assert_eq!(View::from(ViewDto::default()), View::default());
        assert_eq!(View::from(ViewDto { sort: SortKeyDto::Year, descending: true, group: true }),
            View { sort: SortKey::Year, descending: true, group: true });
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ResumeDto {
    pub release_id: i64,
    pub title: String,
    pub credit: Option<String>,
    pub cover: Option<String>,
    pub recording_id: i64,
    pub recording_title: String,
    pub disc: u32,
    pub number: u32,
    pub position_ms: u64,
    pub length_ms: Option<u64>,
    pub idiom: Option<String>,
    pub updated_at: i64,
}

impl ResumeDto {
    pub fn from_row(row: meret_store::ResumeRow, art_dir: &Path) -> Self {
        Self { release_id: row.release.0, title: row.title, credit: row.credit,
            cover: row.cover.map(|a| meret_store::cover_file(art_dir, &a.hash, 256).to_string_lossy().into_owned()),
            recording_id: row.recording.0, recording_title: row.recording_title, disc: row.disc, number: row.number,
            position_ms: row.position_ms, length_ms: row.length_ms, idiom: row.idiom.map(|i| i.as_str().into()), updated_at: row.updated_at }
    }
}
