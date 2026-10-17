//! Planning a query against the store.
//!
//! Clauses the hot columns can answer become bitmap operations and run in
//! microseconds. The rest (free text, people, names) go to FTS5 and the edge
//! table, and their row sets are intersected with the column result.

use meret_query::{Clause, Cmp, Flag, Format, NumField, Query, Term, TimeField};
use roaring::RoaringBitmap;

use crate::columns::{ColumnId, HotColumns};

/// Format codes stored in `HotColumns::format`.
pub mod format_code {
    pub const UNKNOWN: u8 = 0;
    pub const FLAC_CD: u8 = 1;
    pub const HI_RES: u8 = 2;
    pub const DSD: u8 = 3;
    pub const CHIPTUNE: u8 = 4;
    pub const LOSSY: u8 = 5;
    /// A query-only bit, not a best-format category.
    pub const MP3: u8 = 6;

    /// The code for a source, from what its file says about itself.
    pub fn classify(codec: Option<&str>, sample_rate: Option<u32>, bits: Option<u8>, lossless: bool) -> u8 {
        match codec {
            None => UNKNOWN,
            Some("DSD") => DSD,
            Some("SPC" | "NSF" | "VGM" | "GBS" | "PSF") => CHIPTUNE,
            Some(_) if !lossless => LOSSY,
            Some(_) if bits.unwrap_or(16) > 16 || sample_rate.unwrap_or(44_100) > 48_000 => HI_RES,
            Some(_) => FLAC_CD,
        }
    }
}

#[derive(Debug, Default)]
pub struct Plan {
    /// Rows that pass every clause the columns could answer.
    pub rows: Option<RoaringBitmap>,
    /// Clauses left for SQL: text, people, names.
    pub residual: Vec<Clause>,
}

pub fn plan(q: &Query, cols: &HotColumns, now_s: i64) -> Plan {
    let mut out = Plan::default();
    for clause in &q.clauses {
        match columns_answer(&clause.term, cols, now_s) {
            Some(mut set) => {
                if clause.negated {
                    let mut all = cols.all();
                    all -= &set;
                    set = all;
                }
                out.rows = Some(match out.rows.take() {
                    Some(acc) => acc & set,
                    None => set,
                });
            }
            None => out.residual.push(clause.clone()),
        }
    }
    out
}

fn columns_answer(term: &Term, c: &HotColumns, now_s: i64) -> Option<RoaringBitmap> {
    Some(match term {
        Term::Idiom { idiom } => c.equals_u8(&c.idiom, *idiom as u8),
        Term::Number { field, cmp } => {
            let col = match field {
                NumField::Year => ColumnId::Year,
                NumField::Plays => ColumnId::Plays,
                NumField::Length => ColumnId::Length,
                NumField::Dr => ColumnId::Dr,
                NumField::Bpm => return None,
            };
            let (lo, hi) = match *cmp {
                Cmp::Eq(v) => (v, v),
                Cmp::Lt(v) => (f64::MIN, v - f64::EPSILON),
                Cmp::Gt(v) => (v + f64::EPSILON, f64::MAX),
                Cmp::Range(a, b) => (a, b),
            };
            c.range(col, lo, hi)
        }
        Term::Within { field, span } => {
            let col = match field {
                TimeField::LastPlayed => ColumnId::LastPlayed,
                TimeField::Added => ColumnId::Added,
            };
            c.range(col, (now_s - span.as_millis() / 1000) as f64, now_s as f64)
        }
        Term::Format { format } => {
            use format_code::*;
            let mask = match format {
                Format::Flac => (1 << FLAC_CD) | (1 << HI_RES),
                Format::HiRes => 1 << HI_RES,
                Format::Dsd => 1 << DSD,
                Format::Chiptune => 1 << CHIPTUNE,
                Format::Lossy => 1 << LOSSY,
                Format::Mp3 => 1 << MP3,
            };
            c.matching_formats(mask)
        }
        Term::Flag { flag } => match flag {
            Flag::Owned => c.equals_u8(&c.availability, 0) | c.equals_u8(&c.availability, 1),
            Flag::Lossless => c.equals_u8(&c.availability, 0),
            Flag::Streamable => c.equals_u8(&c.availability, 2),
            Flag::Guessed => c.guessed.clone(),
            Flag::Wanted | Flag::Dormant | Flag::Lead => return None,
        },
        Term::Text { .. } | Term::Person { .. } | Term::Named { .. } => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::columns::Row;
    use meret_model::Idiom;

    #[test]
    fn columns_answer_what_they_can_and_leave_the_rest() {
        let cols = HotColumns::from_rows([
            Row { track: 1, idiom: Idiom::Session as u8, year: 1975, plays: 0, ..Default::default() },
            Row { track: 2, idiom: Idiom::Session as u8, year: 1975, plays: 3, ..Default::default() },
            Row { track: 3, idiom: Idiom::Score as u8, year: 1998, plays: 0, ..Default::default() },
        ]);
        let meret_query::Input::Search(q) = meret_query::parse("idiom:session year:1970s plays:0 bill evans").unwrap() else {
            unreachable!()
        };
        let p = plan(&q, &cols, 0);
        assert_eq!(p.rows.unwrap().iter().collect::<Vec<_>>(), vec![0]);
        assert_eq!(p.residual.len(), 2);
    }
}
