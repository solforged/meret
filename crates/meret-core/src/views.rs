use std::collections::HashMap;
use std::sync::Arc;

use meret_model::{AgentId, Idiom, ReleaseId, TrackId};
use meret_query::{Input, parse};
use meret_store::{Artwork, HotColumns, TrackRow, format_code, plan};

use crate::{Core, CoreError, LIST_TTL_S, LISTS, MAX_QUEUE, Result, now_s, queue_items};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SortKey {
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
pub struct View {
    pub sort: SortKey,
    pub descending: bool,
    pub group: bool,
}

/// Track ids survive a hot-column reload; ordinals stay in display order.
pub struct List {
    pub query: String,
    pub view: View,
    pub version: u64,
    pub made_s: i64,
    pub tracks: Vec<TrackId>,
    pub items: Vec<Item>,
    pub releases: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Item {
    Group { release: ReleaseId, first: u32, tracks: u32, length_s: u64, formats: u8 },
    Track(u32),
}

#[derive(Clone, Debug, PartialEq)]
pub struct GroupRow {
    pub release: ReleaseId,
    pub title: String,
    pub year: Option<u16>,
    pub idiom: Option<Idiom>,
    pub album_artist: Option<(AgentId, String)>,
    pub tracks: u32,
    pub length_ms: u64,
    pub formats: Vec<&'static str>,
    pub cover: Option<Artwork>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PageItem {
    Group(GroupRow),
    Track { ordinal: u32, row: TrackRow },
}

#[derive(Clone, Debug, PartialEq)]
pub struct RowsPage {
    pub total_items: usize,
    pub tracks: usize,
    pub releases: usize,
    pub offset: usize,
    pub items: Vec<PageItem>,
}

impl Core {
    /// The latest few (query, view) lists stay cached for cheap paging.
    pub fn list(&self, query: &str, view: &View) -> Result<Arc<List>> {
        let version = self.status.borrow().library_version;
        let now = now_s();
        {
            let mut cached = self.lists.lock();
            cached.retain(|l| l.version == version && now - l.made_s < LIST_TTL_S);
            if let Some(i) = cached.iter().position(|l| l.query == query && l.view == *view) {
                let l = cached.remove(i).expect("found");
                cached.push_front(l.clone());
                return Ok(l);
            }
        }
        let cols = self.columns.read();
        let rows = if query.trim().is_empty() {
            None
        } else {
            match parse(query) {
                Ok(Input::Search(q)) => self.store.answer_residual(plan(&q, &cols, now), &cols)?,
                Ok(Input::Command(_)) => return Err(CoreError::Query("a command, not a search".into())),
                Err(e) => return Err(CoreError::Query(e.to_string())),
            }
        };
        let rows = match rows {
            Some(r) => r.iter().map(|i| i as usize).collect(),
            None => (0..cols.len()).collect(),
        };
        let (tracks, items, releases) = display(&cols, rows, view);
        let list = Arc::new(List { query: query.into(), view: *view, version, made_s: now, tracks, items, releases });
        let mut cached = self.lists.lock();
        cached.retain(|l| l.query != query || l.view != *view);
        cached.truncate(LISTS - 1);
        cached.push_front(list.clone());
        Ok(list)
    }

    /// Pages display items, including group headers; track ordinals omit headers.
    pub fn rows(&self, query: &str, view: &View, offset: usize, limit: usize) -> Result<RowsPage> {
        let list = self.list(query, view)?;
        let page = &list.items[offset.min(list.items.len())..offset.saturating_add(limit).min(list.items.len())];
        let track_ids: Vec<_> = page.iter().filter_map(|item| match item {
            Item::Track(i) => Some(list.tracks[*i as usize]),
            Item::Group { .. } => None,
        }).collect();
        let release_ids: Vec<_> = page.iter().filter_map(|item| match item {
            Item::Group { release, .. } => Some(*release),
            Item::Track(_) => None,
        }).collect();
        let mut tracks: HashMap<_, _> = self.store.track_rows(&track_ids)?.into_iter().map(|r| (r.track, r)).collect();
        let mut heads = self.store.release_heads(&release_ids)?;
        let mut art = self.store.release_art(&release_ids)?;
        let items = page.iter().filter_map(|item| match item {
            Item::Track(i) => Some(PageItem::Track { ordinal: *i, row: tracks.remove(&list.tracks[*i as usize])? }),
            Item::Group { release, tracks, length_s, formats, .. } => {
                let head = heads.remove(release)?;
                Some(PageItem::Group(GroupRow {
                    release: *release,
                    title: head.title,
                    year: head.year,
                    idiom: head.idiom,
                    album_artist: head.album_artist,
                    tracks: *tracks,
                    length_ms: length_s * 1000,
                    formats: format_labels(*formats),
                    cover: art.remove(release),
                }))
            }
        }).collect();
        Ok(RowsPage { total_items: list.items.len(), tracks: list.tracks.len(), releases: list.releases, offset, items })
    }

    /// Replaces the queue from a track ordinal in this view's display order.
    pub fn play_results(&self, query: &str, view: &View, ordinal: usize) -> Result<()> {
        let list = self.list(query, view)?;
        let end = ordinal.saturating_add(MAX_QUEUE).min(list.tracks.len());
        let rows = self.store.track_rows(list.tracks.get(ordinal..end).unwrap_or(&[]))?;
        self.play(queue_items(rows))
    }
}

fn display(cols: &HotColumns, mut rows: Vec<usize>, view: &View) -> (Vec<TrackId>, Vec<Item>, usize) {
    if !view.group {
        let releases = rows.first().map_or(0, |_| 1) + rows.windows(2).filter(|pair| cols.release[pair[0]] != cols.release[pair[1]]).count();
        if view.sort == SortKey::Library {
            if view.descending {
                rows.reverse();
            }
        } else {
            rows.sort_unstable_by(|&a, &b| {
                let key = |i: usize| match view.sort {
                    SortKey::Library => i as u64,
                    SortKey::Title => cols.title_rank[i] as u64,
                    SortKey::Artist => cols.artist_rank[i] as u64,
                    SortKey::Album => cols.album_rank[i] as u64,
                    SortKey::Year => cols.year[i] as u64,
                    SortKey::Length => cols.length_s[i] as u64,
                    SortKey::Format => cols.format[i] as u64,
                };
                let cmp = key(a).cmp(&key(b));
                blank_last(view, cols.year[a] == 0, cols.year[b] == 0)
                    .then(if view.descending { cmp.reverse() } else { cmp })
                    .then_with(|| a.cmp(&b))
            });
        }
        let tracks = rows.into_iter().map(|i| cols.track[i]).collect::<Vec<_>>();
        let items = (0..tracks.len() as u32).map(Item::Track).collect();
        return (tracks, items, releases);
    }

    struct Group {
        start: usize,
        end: usize,
        release: ReleaseId,
        length_s: u64,
        formats: u8,
        key: u64,
    }
    let mut groups: Vec<Group> = Vec::new();
    for (position, &i) in rows.iter().enumerate() {
        if groups.last().is_none_or(|g| g.release.0 != cols.release[i] as i64) {
            let key = match view.sort {
                SortKey::Library | SortKey::Artist => i as u64,
                SortKey::Title | SortKey::Album => cols.album_rank[i] as u64,
                SortKey::Year => cols.year[i] as u64,
                SortKey::Length => 0,
                SortKey::Format => cols.format[i] as u64,
            };
            groups.push(Group { start: position, end: position, release: ReleaseId(cols.release[i] as i64), length_s: 0, formats: 0, key });
        }
        let g = groups.last_mut().expect("one group");
        g.end = position + 1;
        g.length_s += cols.length_s[i] as u64;
        g.formats |= 1 << cols.format[i];
        match view.sort {
            SortKey::Year => g.key = g.key.max(cols.year[i] as u64),
            SortKey::Length => g.key = g.length_s,
            SortKey::Format => g.key = g.key.min(cols.format[i] as u64),
            _ => {}
        }
    }
    if matches!(view.sort, SortKey::Library | SortKey::Artist) {
        if view.descending {
            groups.reverse();
        }
    } else {
        groups.sort_unstable_by(|a, b| {
            let cmp = a.key.cmp(&b.key);
            blank_last(view, a.key == 0, b.key == 0)
                .then(if view.descending { cmp.reverse() } else { cmp })
                .then_with(|| a.start.cmp(&b.start))
        });
    }
    let releases = groups.len();
    let mut tracks = Vec::with_capacity(rows.len());
    let mut items = Vec::with_capacity(rows.len() + groups.len());
    for g in groups {
        items.push(Item::Group { release: g.release, first: tracks.len() as u32, tracks: (g.end - g.start) as u32, length_s: g.length_s, formats: g.formats });
        for &i in &rows[g.start..g.end] {
            items.push(Item::Track(tracks.len() as u32));
            tracks.push(cols.track[i]);
        }
    }
    (tracks, items, releases)
}

/// Rows with no year go after the dated ones whichever way the year runs,
/// so an ascending sort doesn't open on a screen of blanks.
fn blank_last(view: &View, a: bool, b: bool) -> std::cmp::Ordering {
    if view.sort == SortKey::Year { a.cmp(&b) } else { std::cmp::Ordering::Equal }
}

/// Short enough for the table's Format column; the track rows carry the detail.
fn format_labels(bits: u8) -> Vec<&'static str> {
    use format_code::*;
    [(UNKNOWN, "Unknown"), (FLAC_CD, "Lossless"), (HI_RES, "Hi-res"), (DSD, "DSD"), (CHIPTUNE, "Chiptune"), (LOSSY, "Lossy")]
        .into_iter().filter_map(|(code, label)| (bits & (1 << code) != 0).then_some(label)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use meret_store::Row;

    fn columns() -> HotColumns {
        HotColumns::from_rows([
            Row { track: 11, release: 1, year: 1998, title_rank: 1, length_s: 30, format: 1, ..Default::default() },
            Row { track: 12, release: 1, year: 1998, title_rank: 0, length_s: 40, format: 2, ..Default::default() },
            Row { track: 13, release: 1, year: 1998, title_rank: 0, length_s: 50, format: 1, ..Default::default() },
            Row { track: 21, release: 2, year: 2024, title_rank: 0, length_s: 60, format: 1, ..Default::default() },
            Row { track: 22, release: 2, year: 2024, title_rank: 1, length_s: 70, format: 1, ..Default::default() },
        ])
    }

    #[test]
    fn descending_year_groups_keep_disc_track_library_order() {
        let cols = columns();
        let (tracks, items, releases) = display(&cols, (0..cols.len()).collect(), &View { sort: SortKey::Year, descending: true, group: true });
        assert_eq!(tracks, [21, 22, 11, 12, 13].map(TrackId));
        assert_eq!(releases, 2);
        assert_eq!(items[0], Item::Group { release: ReleaseId(2), first: 0, tracks: 2, length_s: 130, formats: 2 });
        assert_eq!(items[3], Item::Group { release: ReleaseId(1), first: 2, tracks: 3, length_s: 120, formats: 6 });
        assert_eq!(items[4..], [Item::Track(2), Item::Track(3), Item::Track(4)]);
    }

    #[test]
    fn rows_without_a_year_sort_last_in_both_directions() {
        let cols = HotColumns::from_rows([
            Row { track: 11, release: 1, year: 0, ..Default::default() },
            Row { track: 21, release: 2, year: 1998, ..Default::default() },
            Row { track: 31, release: 3, year: 2024, ..Default::default() },
        ]);
        for group in [false, true] {
            for (descending, expected) in [(false, [21, 31, 11]), (true, [31, 21, 11])] {
                let (tracks, _, _) = display(&cols, (0..cols.len()).collect(), &View { sort: SortKey::Year, descending, group });
                assert_eq!(tracks, expected.map(TrackId), "group {group}, descending {descending}");
            }
        }
    }

    #[test]
    fn title_sort_keeps_library_order_for_ties_in_both_directions() {
        let cols = columns();
        for (descending, expected) in [(false, [12, 13, 21, 11, 22]), (true, [11, 22, 12, 13, 21])] {
            let (tracks, items, releases) = display(&cols, (0..cols.len()).collect(), &View { sort: SortKey::Title, descending, group: false });
            assert_eq!(tracks, expected.map(TrackId));
            assert_eq!(items, (0..5).map(Item::Track).collect::<Vec<_>>());
            assert_eq!(releases, 2);
        }
    }

    #[test]
    fn loaded_ranks_group_paging_and_cache_keep_track_ordinals() {
        use crate::{CoreConfig, OutputChoice};
        let dir = std::env::temp_dir().join(format!("meret-views-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let (scans, _requests) = crossbeam_channel::unbounded();
        let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() }, scans).unwrap();
        core.store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO agent (id, kind, name, sort_name, rev) VALUES (1, 0, 'Zed', 'Able', 1), (2, 0, 'Beta', NULL, 1), (3, 0, 'Other', 'Aardvark', 1);
                 INSERT INTO release (id, title, year, idiom, rev) VALUES (1, 'Old Album', 1998, 5, 1), (2, 'New Album', 2024, 1, 1);
                 INSERT INTO edition (id, release_id, rev) VALUES (1, 1, 1), (2, 2, 1);
                 INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 2), (2, 1, 1), (3, 2, 1);
                 INSERT INTO recording (id, title, rev) VALUES (11, 'alpha', 1), (12, 'ALPHA', 1), (13, 'Zulu', 1), (21, 'Alpha', 1), (22, 'beta', 1);
                 INSERT INTO track (id, medium_id, recording_id, position, length_ms, rev) VALUES
                     (11, 1, 11, 1, 30000, 1), (12, 2, 12, 2, 40000, 1), (13, 2, 13, 1, 50000, 1), (21, 3, 21, 2, 60000, 1), (22, 3, 22, 1, 70000, 1);
                 INSERT INTO credit (subject_kind, subject_id, agent_id, role, rev) VALUES
                     (3, 1, 1, 'album_artist', 1), (3, 2, 2, 'album_artist', 1), (2, 13, 3, 'artist', 1), (2, 21, 2, 'artist', 1);
                 INSERT INTO root (id, label, path, kind) VALUES (1, 'test', '/test', 'local');
                 INSERT INTO file (id, root_id, rel_path, size, mtime_ns, rev) VALUES
                     (11, 1, '11.flac', 1, 1, 1), (12, 1, '12.flac', 1, 1, 1), (13, 1, '13.flac', 1, 1, 1), (21, 1, '21.flac', 1, 1, 1), (22, 1, '22.flac', 1, 1, 1);
                 INSERT INTO source (track_id, kind, file_id, codec, sample_rate, bits, lossless, rev) VALUES
                     (11, 'file', 11, 'FLAC', 44100, 16, 1, 1), (12, 'file', 12, 'FLAC', 96000, 24, 1, 1), (13, 'file', 13, 'FLAC', 44100, 16, 1, 1),
                     (21, 'file', 21, 'FLAC', 44100, 16, 1, 1), (22, 'file', 22, 'FLAC', 44100, 16, 1, 1);
                 INSERT INTO artwork (hash, width, height) VALUES (X'AB', 64, 64);
                 INSERT INTO entity_artwork (entity_kind, entity_id, hash) VALUES (3, 1, X'AB');"
            )?;
            Ok(())
        }).unwrap();
        let cols = core.store.load_columns().unwrap();
        assert_eq!(cols.track, [13, 12, 11, 22, 21].map(TrackId));
        assert_eq!(cols.release, [1, 1, 1, 2, 2]);
        assert_eq!(cols.artist, [3, 0, 0, 0, 2]);
        assert_eq!(cols.album_artist, [1, 1, 1, 2, 2]);
        assert_eq!(cols.title_rank, [2, 0, 0, 1, 0]);
        assert_eq!(cols.artist_rank, [0, 1, 1, 2, 2]);
        assert_eq!(cols.album_rank, [1, 1, 1, 0, 0]);
        *core.columns.write() = cols;
        let view = View { sort: SortKey::Year, descending: true, group: true };
        let list = core.list("", &view).unwrap();
        assert_eq!(list.tracks, [22, 21, 13, 12, 11].map(TrackId));
        assert!(Arc::ptr_eq(&list, &core.list("", &view).unwrap()));
        let default = core.list("", &View::default()).unwrap();
        assert!(!Arc::ptr_eq(&list, &default));
        assert_eq!(default.tracks, [13, 12, 11, 22, 21].map(TrackId));
        assert_eq!(core.search("", 0, 5).unwrap().track_hits.iter().map(|(i, r)| (*i, r.track)).collect::<Vec<_>>(),
            [(0, TrackId(13)), (1, TrackId(12)), (2, TrackId(11)), (3, TrackId(22)), (4, TrackId(21))]);
        let page = core.rows("", &view, 0, 4).unwrap();
        assert_eq!((page.total_items, page.tracks, page.releases), (7, 5, 2));
        let PageItem::Group(new) = &page.items[0] else { panic!() };
        assert_eq!((&*new.title, new.tracks, new.length_ms), ("New Album", 2, 130000));
        assert_eq!(new.album_artist, Some((AgentId(2), "Beta".into())));
        assert!(new.cover.is_none());
        let PageItem::Group(old) = &page.items[3] else { panic!() };
        assert_eq!(old.formats, ["Lossless", "Hi-res"]);
        assert_eq!(old.cover.as_ref().unwrap().hash, "ab");
        let middle = core.rows("", &view, 4, 2).unwrap();
        assert_eq!(middle.items.iter().map(|item| match item {
            PageItem::Track { ordinal, row } => (*ordinal, row.disc, row.number),
            _ => panic!(),
        }).collect::<Vec<_>>(), [(2, 1, 1), (3, 1, 2)]);
        assert!(core.rows("", &view, usize::MAX, usize::MAX).unwrap().items.is_empty());
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
