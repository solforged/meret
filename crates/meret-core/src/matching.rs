//! Finding MusicBrainz IDs for releases the tags didn't identify, by album
//! title and album artist. A match must be unambiguous: the same title, one of
//! the album artists among the credited names, at least as many tracks as you
//! have (and no more than a quarter extra), and a single release group. A
//! matched release is then looked up like a tagged one, but its tracks pair
//! with MusicBrainz's by title rather than by position.

use meret_provider::{Catalog, CatalogHit, CatalogQuery, Context, ProviderError};
use meret_store::{NewJob, Store};
use rusqlite::{OptionalExtension, params};

use crate::Core;

const PREFIX: &str = "fetch:musicbrainz:match:";

/// The job key for matching release `id` by name.
pub(crate) fn key(id: i64) -> String {
    format!("{PREFIX}{id}")
}

/// The release a match job is for.
pub(crate) fn release_of(key: &str) -> Option<i64> {
    key.strip_prefix(PREFIX)?.parse().ok()
}

/// What your tags say about a release, as a match needs it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Local {
    pub title: String,
    /// The album artists, else the one artist every track credits.
    pub artists: Vec<String>,
    pub tracks: u32,
    pub discs: u32,
}

pub(crate) fn local(store: &Store, release: i64) -> meret_store::Result<Option<Local>> {
    store.read(|c| {
        let Some(title) = c.query_row("SELECT title FROM release WHERE id = ?1", [release], |r| r.get::<_, String>(0)).optional()? else {
            return Ok(None);
        };
        let names = |sql: &str| -> rusqlite::Result<Vec<String>> {
            c.prepare(sql)?.query_map([release], |r| r.get(0))?.collect()
        };
        let mut artists = names(
            "SELECT a.name FROM credit cr JOIN agent a ON a.id = cr.agent_id
             WHERE cr.subject_kind = 3 AND cr.subject_id = ?1 AND cr.role = 'album_artist' ORDER BY cr.sort, cr.id",
        )?;
        if artists.is_empty() {
            artists = names(
                "SELECT DISTINCT a.name FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
                 JOIN credit cr ON cr.subject_kind = 2 AND cr.subject_id = t.recording_id AND cr.role = 'artist'
                 JOIN agent a ON a.id = cr.agent_id WHERE e.release_id = ?1 AND e.is_default = 1",
            )?;
            if artists.len() > 1 { artists.clear() }
        }
        let (tracks, discs) = c.query_row(
            "SELECT COUNT(*), COUNT(DISTINCT m.id) FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
             WHERE e.release_id = ?1 AND e.is_default = 1",
            [release], |r| Ok((r.get::<_, i64>(0)? as u32, r.get::<_, i64>(1)? as u32)),
        )?;
        Ok((tracks > 0).then_some(Local { title, artists, tracks, discs }))
    })
}

/// Lower case, letters and digits only, words single-spaced: "Sid Meier’s" and
/// "Sid Meier's" agree, as do "Tenchu: Stealth Assassins" and "Tenchu - Stealth Assassins".
pub(crate) fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for word in text.split(|c: char| !c.is_alphanumeric() && !matches!(c, '\'' | '’' | '‘')) {
        let word: String = word.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect();
        if word.is_empty() { continue }
        if !out.is_empty() { out.push(' ') }
        out.push_str(&word);
    }
    out
}

/// A person's name without initials: "Justin E. Bell" is Justin Bell.
fn person(name: &str) -> String {
    let folded = fold(name);
    let full: Vec<&str> = folded.split(' ').filter(|w| w.chars().count() > 1).collect();
    if full.is_empty() { folded } else { full.join(" ") }
}

/// Every name the credited people go by; "Knorr, Geoff" is Geoff Knorr.
fn names(hit: &CatalogHit) -> Vec<String> {
    let mut names: Vec<String> = hit.artists.iter().map(|n| person(n)).collect();
    names.extend(hit.artists.iter().filter_map(|n| n.split_once(", ")).map(|(last, first)| person(&format!("{first} {last}"))));
    names.push(person(&hit.artist));
    names
}

/// The search is loose, so this decides: the same title, one of your album
/// artists among the credited names (or, with none, the catalogue's best
/// score), and room for your tracks without a quarter more.
fn fits(local: &Local, hit: &CatalogHit) -> bool {
    let Some(tracks) = hit.tracks else { return false };
    let artist = if local.artists.is_empty() {
        hit.score >= 1.0
    } else {
        let names = names(hit);
        local.artists.iter().any(|a| names.contains(&person(a)))
    };
    fold(&hit.title) == fold(&local.title) && artist && tracks >= local.tracks && tracks * 4 <= local.tracks * 5
}

/// The one release among `hits` your release is, if there is exactly one
/// release group it could be. Within the group, the edition with your track
/// and disc counts wins, then the catalogue's ranking.
pub(crate) fn choose<'h>(local: &Local, hits: &'h [CatalogHit]) -> Option<&'h CatalogHit> {
    let fitting: Vec<&CatalogHit> = hits.iter().filter(|h| fits(local, h)).collect();
    let exact: Vec<&CatalogHit> = fitting.iter().copied().filter(|h| h.tracks == Some(local.tracks)).collect();
    let one_group = |hits: &[&CatalogHit]| hits.windows(2).all(|w| w[0].group == w[1].group);
    let pool = if one_group(&fitting) { fitting } else if !exact.is_empty() && one_group(&exact) { exact } else { return None };
    pool.into_iter().max_by(|a, b| {
        let rank = |h: &CatalogHit| (h.tracks == Some(local.tracks), h.discs == Some(local.discs));
        rank(a).cmp(&rank(b)).then(a.score.total_cmp(&b.score)).then(b.subject.value.cmp(&a.subject.value))
    })
}

/// Searches MusicBrainz for `release` and records the match, if any. The
/// outer error is the request's; the inner, writing what it found.
pub(crate) fn run(core: &Core, ctx: &Context, release: i64) -> Result<meret_store::Result<Vec<NewJob>>, ProviderError> {
    let local = match local(&core.store, release) {
        Ok(Some(local)) => local,
        Ok(None) => return Ok(Ok(vec![])),
        Err(e) => return Ok(Err(e)),
    };
    let query = CatalogQuery { release: Some(local.title.clone()), artist: local.artists.first().cloned(), ..Default::default() };
    let hits = core.runtime.block_on(provider_musicbrainz::MusicBrainz.search(ctx, &query))?;
    let Some(hit) = choose(&local, &hits) else { return Ok(Ok(vec![])) };
    Ok(crate::lookups::matched(&core.store, release, hit, Context::now_ms()))
}

/// Seeds a match for every release with tracks and no MusicBrainz ID.
pub(crate) fn unidentified(store: &Store) -> meret_store::Result<Vec<i64>> {
    store.read(|c| c.prepare(
        "SELECT r.id FROM release r WHERE NOT EXISTS (SELECT 1 FROM external_id x WHERE x.entity_kind = 3 AND x.entity_id = r.id AND x.namespace = 'mbid')
         AND EXISTS (SELECT 1 FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id WHERE e.release_id = r.id)",
    )?.query_map(params![], |r| r.get(0))?.collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use meret_provider::{ExternalRef, RefKind};

    fn hit(id: &str, title: &str, artists: &[&str], tracks: u32, discs: u32, group: &str, score: f32) -> CatalogHit {
        CatalogHit {
            subject: ExternalRef::mbid(RefKind::Release, id), title: title.into(), artist: artists.first().copied().unwrap_or("").into(),
            length_ms: None, score, tracks: Some(tracks), discs: Some(discs),
            artists: artists.iter().map(|a| a.to_string()).collect(), group: Some(group.into()),
        }
    }

    fn mine(title: &str, artists: &[&str], tracks: u32, discs: u32) -> Local {
        Local { title: title.into(), artists: artists.iter().map(|a| a.to_string()).collect(), tracks, discs }
    }

    #[test]
    fn a_match_needs_the_title_an_artist_and_room_for_your_tracks() {
        let local = mine("Fixture Suite: Act One", &["Ada M. Brennan"], 99, 4);
        let by_sort_name = [hit("a", "Fixture Suite – Act One", &["Brennan, Ada"], 102, 4, "g", 0.8)];
        assert_eq!(choose(&local, &by_sort_name).map(|h| h.subject.value.as_str()), Some("a"));
        for wrong in [
            hit("b", "Fixture Suite: Act Two", &["Ada Brennan"], 99, 4, "g", 1.0),
            hit("c", "Fixture Suite: Act One", &["Tomas Vey"], 99, 4, "g", 1.0),
            hit("d", "Fixture Suite: Act One", &["Ada Brennan"], 98, 4, "g", 1.0),
            hit("e", "Fixture Suite: Act One", &["Ada Brennan"], 130, 5, "g", 1.0),
        ] {
            assert_eq!(choose(&local, std::slice::from_ref(&wrong)), None, "{}", wrong.subject.value);
        }
    }

    #[test]
    fn two_release_groups_are_ambiguous_unless_one_has_your_track_count() {
        let local = mine("Fixture Suite", &["Ada Brennan"], 10, 1);
        let ambiguous = [hit("a", "Fixture Suite", &["Ada Brennan"], 10, 1, "g1", 1.0), hit("b", "Fixture Suite", &["Ada Brennan"], 10, 1, "g2", 1.0)];
        assert_eq!(choose(&local, &ambiguous), None);
        let settled = [hit("a", "Fixture Suite", &["Ada Brennan"], 12, 1, "g1", 1.0), hit("b", "Fixture Suite", &["Ada Brennan"], 10, 1, "g2", 0.95)];
        assert_eq!(choose(&local, &settled).map(|h| h.subject.value.as_str()), Some("b"));
        let editions = [
            hit("a", "Fixture Suite", &["Ada Brennan"], 11, 1, "g1", 1.0),
            hit("b", "Fixture Suite", &["Ada Brennan"], 10, 2, "g1", 1.0),
            hit("c", "Fixture Suite", &["Ada Brennan"], 10, 1, "g1", 0.95),
        ];
        assert_eq!(choose(&local, &editions).map(|h| h.subject.value.as_str()), Some("c"));
    }

    #[test]
    fn without_an_artist_only_a_perfect_score_matches() {
        let local = mine("Fixture Suite", &[], 10, 1);
        assert_eq!(choose(&local, &[hit("a", "Fixture Suite", &["Tomas Vey"], 10, 1, "g", 0.97)]), None);
        assert!(choose(&local, &[hit("a", "Fixture Suite", &["Tomas Vey"], 10, 1, "g", 1.0)]).is_some());
    }
}
