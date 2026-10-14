//! The hot column store.
//!
//! A struct-of-arrays copy of the columns the table pane sorts, filters and
//! brushes, indexed by a dense row number. About 64 bytes a track: 64 MB for a
//! million. Filters return roaring bitmaps of row numbers; facet counts and
//! histograms are single passes over one array.
//!
//! The store rebuilds this at start-up from SQLite (or from a snapshot file)
//! and patches it as writes commit.

use meret_model::{Idiom, TrackId};
use roaring::RoaringBitmap;

/// One row as loaded from SQLite.
#[derive(Clone, Debug, Default)]
pub struct Row {
    pub track: i64,
    pub release: u32,
    /// 0 when there is no credited artist.
    pub artist: u32,
    pub album_artist: u32,
    pub title_rank: u32,
    pub artist_rank: u32,
    pub album_rank: u32,
    pub year: u16,
    pub length_s: u32,
    pub plays: u32,
    /// Unix seconds; 0 for never.
    pub last_played: i64,
    pub added: i64,
    /// 0 for unknown.
    pub dr: u8,
    /// `Idiom as u8`; 0 for unknown.
    pub idiom: u8,
    /// See `Format` codes in `plan.rs`.
    pub format: u8,
    /// `Availability::rank`.
    pub availability: u8,
    pub guessed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColumnId {
    Year,
    Length,
    Plays,
    LastPlayed,
    Added,
    Dr,
}

/// Bin counts plus the range they cover, ready to draw as a column header.
#[derive(Clone, Debug, PartialEq)]
pub struct Histogram {
    pub lo: f64,
    pub hi: f64,
    pub bins: Vec<u32>,
}

#[derive(Default)]
pub struct HotColumns {
    pub track: Vec<TrackId>,
    pub release: Vec<u32>,
    pub artist: Vec<u32>,
    pub album_artist: Vec<u32>,
    pub title_rank: Vec<u32>,
    pub artist_rank: Vec<u32>,
    pub album_rank: Vec<u32>,
    pub year: Vec<u16>,
    pub length_s: Vec<u32>,
    pub plays: Vec<u32>,
    pub last_played: Vec<i64>,
    pub added: Vec<i64>,
    pub dr: Vec<u8>,
    pub idiom: Vec<u8>,
    pub format: Vec<u8>,
    pub availability: Vec<u8>,
    pub guessed: RoaringBitmap,
}

impl HotColumns {
    pub fn from_rows(rows: impl IntoIterator<Item = Row>) -> Self {
        let mut c = HotColumns::default();
        for r in rows {
            c.push(r);
        }
        c
    }

    pub fn push(&mut self, r: Row) {
        let i = self.track.len() as u32;
        self.track.push(TrackId(r.track));
        self.release.push(r.release);
        self.artist.push(r.artist);
        self.album_artist.push(r.album_artist);
        self.title_rank.push(r.title_rank);
        self.artist_rank.push(r.artist_rank);
        self.album_rank.push(r.album_rank);
        self.year.push(r.year);
        self.length_s.push(r.length_s);
        self.plays.push(r.plays);
        self.last_played.push(r.last_played);
        self.added.push(r.added);
        self.dr.push(r.dr);
        self.idiom.push(r.idiom);
        self.format.push(r.format);
        self.availability.push(r.availability);
        if r.guessed {
            self.guessed.insert(i);
        }
    }

    pub fn len(&self) -> usize {
        self.track.len()
    }

    pub fn is_empty(&self) -> bool {
        self.track.is_empty()
    }

    pub fn all(&self) -> RoaringBitmap {
        let mut b = RoaringBitmap::new();
        b.insert_range(0..self.len() as u32);
        b
    }

    /// Rows whose value in `col` lies in `lo..=hi`. Unknown values (0) never match.
    pub fn range(&self, col: ColumnId, lo: f64, hi: f64) -> RoaringBitmap {
        fn scan<T: Copy + Into<f64> + PartialEq + Default>(v: &[T], lo: f64, hi: f64) -> RoaringBitmap {
            let unknown = T::default();
            RoaringBitmap::from_sorted_iter(v.iter().enumerate().filter_map(|(i, &x)| {
                let f: f64 = x.into();
                (x != unknown && f >= lo && f <= hi).then_some(i as u32)
            }))
            .expect("indices are sorted")
        }
        match col {
            ColumnId::Year => scan(&self.year, lo, hi),
            ColumnId::Length => scan(&self.length_s, lo, hi),
            ColumnId::Plays => {
                // Zero plays is a real value, not "unknown".
                RoaringBitmap::from_sorted_iter(self.plays.iter().enumerate().filter_map(|(i, &p)| {
                    (p as f64 >= lo && p as f64 <= hi).then_some(i as u32)
                }))
                .expect("indices are sorted")
            }
            ColumnId::LastPlayed => scan_i64(&self.last_played, lo, hi),
            ColumnId::Added => scan_i64(&self.added, lo, hi),
            ColumnId::Dr => scan(&self.dr, lo, hi),
        }
    }

    pub fn equals_u8(&self, col: &[u8], value: u8) -> RoaringBitmap {
        RoaringBitmap::from_sorted_iter(
            col.iter().enumerate().filter_map(|(i, &x)| (x == value).then_some(i as u32)),
        )
        .expect("indices are sorted")
    }

    /// Facet counts for the idiom column, within a selection.
    pub fn idiom_counts(&self, within: &RoaringBitmap) -> [u32; 8] {
        let mut out = [0u32; 8];
        for i in within {
            let v = self.idiom[i as usize] as usize;
            if v < out.len() {
                out[v] += 1;
            }
        }
        out
    }

    pub fn idiom_of(&self, row: u32) -> Option<Idiom> {
        Idiom::ALL.into_iter().find(|i| *i as u8 == self.idiom[row as usize])
    }

    /// The histogram drawn in a column header: the shape of `col` over
    /// `within`, split into `bins` equal ranges between `lo` and `hi`.
    pub fn histogram(&self, col: ColumnId, within: &RoaringBitmap, lo: f64, hi: f64, bins: usize) -> Histogram {
        let mut out = vec![0u32; bins.max(1)];
        let width = (hi - lo) / out.len() as f64;
        let mut put = |f: f64| {
            if f >= lo && f <= hi && width > 0.0 {
                let b = (((f - lo) / width) as usize).min(out.len() - 1);
                out[b] += 1;
            }
        };
        match col {
            ColumnId::Year => within.iter().filter(|&i| self.year[i as usize] != 0).for_each(|i| put(self.year[i as usize] as f64)),
            ColumnId::Length => within.iter().for_each(|i| put(self.length_s[i as usize] as f64)),
            ColumnId::Plays => within.iter().for_each(|i| put(self.plays[i as usize] as f64)),
            ColumnId::LastPlayed => within.iter().filter(|&i| self.last_played[i as usize] != 0).for_each(|i| put(self.last_played[i as usize] as f64)),
            ColumnId::Added => within.iter().for_each(|i| put(self.added[i as usize] as f64)),
            ColumnId::Dr => within.iter().filter(|&i| self.dr[i as usize] != 0).for_each(|i| put(self.dr[i as usize] as f64)),
        }
        Histogram { lo, hi, bins: out }
    }
}

fn scan_i64(v: &[i64], lo: f64, hi: f64) -> RoaringBitmap {
    RoaringBitmap::from_sorted_iter(v.iter().enumerate().filter_map(|(i, &x)| {
        (x != 0 && x as f64 >= lo && x as f64 <= hi).then_some(i as u32)
    }))
    .expect("indices are sorted")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> HotColumns {
        HotColumns::from_rows([
            Row { track: 1, year: 1998, length_s: 391, plays: 212, idiom: Idiom::Score as u8, dr: 10, ..Default::default() },
            Row { track: 2, year: 1995, length_s: 188, plays: 311, idiom: Idiom::Score as u8, ..Default::default() },
            Row { track: 3, year: 1976, length_s: 822, plays: 14, idiom: Idiom::Work as u8, dr: 14, ..Default::default() },
            Row { track: 4, year: 1961, length_s: 367, plays: 0, idiom: Idiom::Session as u8, dr: 13, ..Default::default() },
            Row { track: 5, year: 0, length_s: 300, plays: 0, idiom: 0, ..Default::default() },
        ])
    }

    #[test]
    fn ranges_skip_unknowns_but_keep_zero_plays() {
        let c = sample();
        assert_eq!(c.range(ColumnId::Year, 1990.0, 1999.0).iter().collect::<Vec<_>>(), vec![0, 1]);
        assert_eq!(c.range(ColumnId::Year, 0.0, 3000.0).len(), 4);
        assert_eq!(c.range(ColumnId::Plays, 0.0, 0.0).iter().collect::<Vec<_>>(), vec![3, 4]);
        assert_eq!(c.range(ColumnId::Dr, 12.0, 20.0).iter().collect::<Vec<_>>(), vec![2, 3]);
    }

    #[test]
    fn histogram_by_decade() {
        let c = sample();
        let h = c.histogram(ColumnId::Year, &c.all(), 1960.0, 2000.0, 4);
        assert_eq!(h.bins, vec![1, 1, 0, 2]);
    }

    #[test]
    fn facets_count_within_a_selection() {
        let c = sample();
        let counts = c.idiom_counts(&c.range(ColumnId::Plays, 1.0, 1e9));
        assert_eq!(counts[Idiom::Score as usize], 2);
        assert_eq!(counts[Idiom::Work as usize], 1);
        assert_eq!(counts[Idiom::Session as usize], 0);
    }

    /// `cargo test -p meret-store --release -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn brushing_a_million_rows() {
        let rows = (0..1_000_000i64).map(|i| Row {
            track: i,
            year: 1950 + (i % 76) as u16,
            length_s: 60 + (i % 900) as u32,
            plays: (i % 400) as u32,
            last_played: 1_700_000_000 + i * 31,
            idiom: 1 + (i % 7) as u8,
            ..Default::default()
        });
        let c = HotColumns::from_rows(rows);
        let t = std::time::Instant::now();
        let sel = c.range(ColumnId::LastPlayed, 1_710_000_000.0, 1_720_000_000.0);
        let h = c.histogram(ColumnId::Year, &sel, 1950.0, 2026.0, 76);
        let f = c.idiom_counts(&sel);
        let took = t.elapsed();
        println!("brush + histogram + facets over 1M rows: {took:?} ({} selected, {} bins, {f:?})", sel.len(), h.bins.len());
    }
}
