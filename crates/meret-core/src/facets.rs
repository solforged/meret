use std::collections::HashMap;

use meret_model::{AgentId, Idiom, ReleaseId};
use meret_query::{Clause, Input, NameField, Query, Term, parse};
use meret_store::{HotColumns, plan};

use crate::{Core, CoreError, Result, now_s};

#[derive(Clone, Debug, PartialEq)]
pub struct Facets {
    pub idioms: FacetColumn,
    pub people: FacetColumn,
    pub releases: FacetColumn,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FacetColumn {
    pub all_query: String,
    pub tracks: u32,
    pub entries: Vec<Facet>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Facet {
    pub id: i64,
    pub name: String,
    pub tracks: u32,
    pub selected: bool,
    pub query: String,
}

impl Core {
    /// Idiom → person → release; each column counts only its upstream filters.
    pub fn facets(&self, query: &str) -> Result<Facets> {
        let q = match parse(query) {
            Ok(Input::Search(q)) => q,
            Ok(Input::Command(_)) => return Err(CoreError::Query("a command, not a search".into())),
            Err(e) => return Err(CoreError::Query(e.to_string())),
        };
        let cols = self.columns.read();
        let now = now_s();
        let within = |column| {
            let query = upstream(&q, column);
            self.store.answer_residual(plan(&query, &cols, now), &cols).map(|rows| rows.unwrap_or_else(|| cols.all()))
        };
        let idiom_rows = within(0)?;
        let people_rows = within(1)?;
        let release_rows = within(2)?;
        let counts = cols.idiom_counts(&idiom_rows);
        let idioms = FacetColumn {
            all_query: upstream(&q, 0).to_string(),
            tracks: idiom_rows.len() as u32,
            entries: Idiom::ALL.into_iter().filter_map(|idiom| {
                let count = counts[idiom as usize];
                (count > 0).then(|| facet(&q, 0, idiom as i64, plural(idiom).into(), count, Term::Idiom { idiom }))
            }).collect(),
        };

        let people_counts = people_counts(&cols, people_rows.iter().map(|i| i as usize));
        let agents = people_counts.keys().map(|&id| AgentId(id as i64)).collect::<Vec<_>>();
        let names = self.store.agent_names(&agents)?;
        let mut people = FacetColumn {
            all_query: upstream(&q, 1).to_string(),
            tracks: people_rows.len() as u32,
            entries: people_counts.into_iter().filter_map(|(id, count)| {
                let name = names.get(&AgentId(id as i64))?.clone();
                Some(facet(&q, 1, id as i64, name.clone(), count, Term::Person { role: None, name }))
            }).collect(),
        };
        sort_names(&mut people.entries);

        let mut release_counts = HashMap::<u32, u32>::new();
        for i in release_rows.iter() {
            *release_counts.entry(cols.release[i as usize]).or_default() += 1;
        }
        let ids = release_counts.keys().map(|&id| ReleaseId(id as i64)).collect::<Vec<_>>();
        let heads = self.store.release_heads(&ids)?;
        let mut releases = FacetColumn {
            all_query: upstream(&q, 2).to_string(),
            tracks: release_rows.len() as u32,
            entries: release_counts.into_iter().filter_map(|(id, count)| {
                let name = heads.get(&ReleaseId(id as i64))?.title.clone();
                Some(facet(&q, 2, id as i64, name.clone(), count, Term::Named { field: NameField::Release, value: name }))
            }).collect(),
        };
        sort_names(&mut releases.entries);
        Ok(Facets { idioms, people, releases })
    }
}

fn people_counts(cols: &HotColumns, rows: impl Iterator<Item = usize>) -> HashMap<u32, u32> {
    let mut counts = HashMap::new();
    for i in rows {
        for &person in cols.people(i) {
            *counts.entry(person).or_default() += 1;
        }
    }
    counts
}

fn browser_column(clause: &Clause) -> Option<u8> {
    if clause.negated {
        return None;
    }
    match clause.term {
        Term::Idiom { .. } => Some(0),
        Term::Person { role: None, .. } => Some(1),
        Term::Named { field: NameField::Release, .. } => Some(2),
        _ => None,
    }
}

fn upstream(q: &Query, column: u8) -> Query {
    Query { clauses: q.clauses.iter().filter(|c| browser_column(c).is_none_or(|n| n < column)).cloned().collect() }
}

fn matches(a: &Term, b: &Term) -> bool {
    match (a, b) {
        (Term::Idiom { idiom: a }, Term::Idiom { idiom: b }) => a == b,
        (Term::Person { name: a, .. }, Term::Person { name: b, .. }) => a.eq_ignore_ascii_case(b),
        (Term::Named { value: a, .. }, Term::Named { value: b, .. }) => a.eq_ignore_ascii_case(b),
        _ => false,
    }
}

fn facet(q: &Query, column: u8, id: i64, name: String, tracks: u32, term: Term) -> Facet {
    let selected = q.clauses.iter().any(|c| browser_column(c) == Some(column) && matches(&c.term, &term));
    let query = if selected {
        Query { clauses: q.clauses.iter().filter(|c| !(browser_column(c) == Some(column) && matches(&c.term, &term))).cloned().collect() }
    } else {
        let mut query = upstream(q, column);
        query.clauses.push(Clause { negated: false, term });
        query
    };
    Facet { id, name, tracks, selected, query: query.to_string() }
}

fn sort_names(entries: &mut [Facet]) {
    entries.sort_by_cached_key(|f| (f.name.to_lowercase(), f.id));
}

fn plural(idiom: Idiom) -> &'static str {
    match idiom {
        Idiom::Album => "Albums",
        Idiom::Song => "Songs",
        Idiom::Work => "Works",
        Idiom::Session => "Sessions",
        Idiom::Score => "Scores",
        Idiom::Set => "Sets",
        Idiom::Spoken => "Spoken",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CoreConfig, OutputChoice};
    use meret_store::Row;

    #[test]
    fn joint_credits_count_each_person_once_across_roles() {
        let cols = HotColumns::from_rows([
            Row { track: 1, artist: 1, album_artist: 1, people: vec![1, 2], ..Default::default() },
            Row { track: 2, artist: 1, album_artist: 3, people: vec![1, 2, 3], ..Default::default() },
            Row { track: 3, artist: 2, album_artist: 2, ..Default::default() },
        ]);
        assert_eq!(people_counts(&cols, 0..3), HashMap::from([(1, 2), (2, 3), (3, 1)]));
        assert_eq!(people_counts(&cols, [1].into_iter()), HashMap::from([(1, 1), (2, 1), (3, 1)]));
    }

    #[test]
    fn facet_cascade_preserves_base_and_toggles_only_selected_clauses() {
        let dir = std::env::temp_dir().join(format!("meret-facets-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let (scans, _requests) = crossbeam_channel::unbounded();
        let core = Core::new(CoreConfig { data_dir: dir.clone(), output: OutputChoice::Null { speed: 1.0 }, contact: "test".into() }, scans).unwrap();
        core.store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO agent (id, kind, name, rev) VALUES (1, 0, 'Mark Cromer', 1), (2, 0, 'Other Person', 1);
                 INSERT INTO release (id, title, rev) VALUES (1, 'First Score', 1), (2, 'Second Score', 1), (3, 'An Album', 1);
                 INSERT INTO edition (id, release_id, rev) VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1);
                 INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 1), (2, 2, 1), (3, 3, 1);
                 INSERT INTO recording (id, title, rev) VALUES (1, 'One', 1), (2, 'Two', 1), (3, 'Three', 1), (4, 'Four', 1);
                 INSERT INTO track (id, medium_id, recording_id, position, rev) VALUES (1, 1, 1, 1, 1), (2, 1, 2, 2, 1), (3, 2, 3, 1, 1), (4, 3, 4, 1, 1);
                 INSERT INTO credit (subject_kind, subject_id, agent_id, role, rev) VALUES (3, 1, 1, 'album_artist', 1), (3, 2, 2, 'album_artist', 1), (3, 3, 2, 'album_artist', 1);"
            )?;
            Ok(())
        }).unwrap();
        *core.columns.write() = HotColumns::from_rows([
            Row { track: 1, release: 1, artist: 1, album_artist: 1, idiom: 5, year: 2000, ..Default::default() },
            Row { track: 2, release: 1, artist: 2, album_artist: 1, idiom: 5, year: 2001, ..Default::default() },
            Row { track: 3, release: 2, artist: 2, album_artist: 2, idiom: 5, year: 2002, ..Default::default() },
            Row { track: 4, release: 3, artist: 2, album_artist: 2, idiom: 1, year: 2003, ..Default::default() },
            Row { track: 5, release: 3, artist: 2, album_artist: 2, idiom: 1, year: 1980, ..Default::default() },
        ]);
        let f = core.facets("year:>1990 idiom:score by:\"MARK CROMER\" release:\"First Score\"").unwrap();
        assert_eq!((f.idioms.tracks, f.people.tracks, f.releases.tracks), (4, 3, 2));
        assert_eq!(f.idioms.all_query, "year:>1990");
        assert_eq!(f.people.all_query, "year:>1990 idiom:score");
        assert_eq!(f.releases.all_query, "year:>1990 idiom:score by:\"MARK CROMER\"");
        assert_eq!(f.idioms.entries.iter().map(|e| (&*e.name, e.tracks)).collect::<Vec<_>>(), [("Albums", 1), ("Scores", 3)]);
        assert_eq!(f.people.entries.iter().map(|e| (&*e.name, e.tracks)).collect::<Vec<_>>(), [("Mark Cromer", 2), ("Other Person", 2)]);
        assert!(f.people.entries[0].selected);
        assert_eq!(f.people.entries[0].query, "year:>1990 idiom:score release:\"First Score\"");
        assert_eq!(f.people.entries[1].query, "year:>1990 idiom:score by:\"Other Person\"");
        assert_eq!(f.idioms.entries[0].query, "year:>1990 idiom:album");
        assert!(f.idioms.entries[1].selected);
        assert_eq!(f.idioms.entries[1].query, "year:>1990 by:\"MARK CROMER\" release:\"First Score\"");
        assert_eq!(f.releases.entries.len(), 1);
        assert!(f.releases.entries[0].selected);
        assert_eq!(f.releases.entries[0].query, "year:>1990 idiom:score by:\"MARK CROMER\"");
        drop(core);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn negations_and_role_clauses_stay_in_the_base_query() {
        let Input::Search(q) = parse("-idiom:score performer:Mark -by:Other -release:Live idiom:album by:Mark release:Studio").unwrap() else { panic!() };
        assert_eq!(upstream(&q, 0).to_string(), "-idiom:score performer:Mark -by:Other -release:Live");
        let row = facet(&q, 2, 1, "Another Release".into(), 1, Term::Named { field: NameField::Release, value: "Another Release".into() });
        assert!(!row.selected);
        assert_eq!(row.query, "-idiom:score performer:Mark -by:Other -release:Live idiom:album by:Mark release:\"Another Release\"");
    }
}
