//! Placing scores in their games, from Wikidata. A release is searched for
//! by its title with the soundtrack words taken off ("Tyranny Official
//! Soundtrack (Deluxe Edition)" is Tyranny), then with its last part dropped
//! ("Sid Meier's Civilization V: America" is Civilization V). A game whose
//! name or alias is that title wins over one whose name only starts with it,
//! and either must be the only one, or the only one sharing a composer with
//! the release. A release that isn't marked a score and doesn't say
//! soundtrack in its title needs that shared composer too, so an album that
//! happens to share a game's name stays an album.

use meret_library::idiom::source as idiom;
use meret_model::{EntityKind, Idiom};
use meret_model::credit::{clean_name, name_key};
use meret_provider::{Context, ProviderError};
use meret_store::{NewJob, Store};
use provider_wikidata::Game;
use rusqlite::{OptionalExtension, Transaction, params};

use crate::Core;
use crate::matching::{fold, person};

pub(crate) const PROVIDER: &str = "wikidata";
const PREFIX: &str = "fetch:wikidata:game:";

/// The job key for placing release `id` in its game.
pub(crate) fn key(id: i64) -> String {
    format!("{PREFIX}{id}")
}

/// The release a game job is for.
pub(crate) fn release_of(key: &str) -> Option<i64> {
    key.strip_prefix(PREFIX)?.parse().ok()
}

/// Releases with tracks and no game yet that could be scores: marked
/// scores, and albums, which is what untagged rips become.
pub(crate) fn unplaced(store: &Store) -> meret_store::Result<Vec<i64>> {
    store.read(|c| c.prepare(
        "SELECT r.id FROM release r WHERE (r.idiom IS NULL OR r.idiom IN (1, 5))
         AND NOT EXISTS (SELECT 1 FROM edge g WHERE g.from_kind = 3 AND g.from_id = r.id AND g.kind = 'soundtrack_of')
         AND EXISTS (SELECT 1 FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id WHERE e.release_id = r.id)",
    )?.query_map([], |r| r.get(0))?.collect())
}

/// Words a soundtrack's title adds to its game's name, longest first.
const SOUNDTRACK: [&str; 13] = [
    "original video game soundtrack", "original game soundtrack", "original soundtrack", "official soundtrack",
    "game soundtrack", "soundtrack", "original score", "o.s.t", "ost", "score", "music", "deluxe edition", "complete",
];

/// Whether a title says it's a soundtrack.
fn says_soundtrack(title: &str) -> bool {
    let folded = format!(" {} ", fold(title));
    ["soundtrack", "ost", "o s t", "score"].iter().any(|w| folded.contains(&format!(" {w} ")))
}

/// The names to search for, most specific first.
pub(crate) fn candidates(title: &str) -> Vec<String> {
    let mut base = title.to_string();
    // Bracketed notes about the release: "(Original Game Soundtrack)", "[Deluxe Edition]".
    while let Some((open, close)) = ["(", "["].iter().zip([")", "]"]).find_map(|(o, c)| {
        let open = base.find(o)?;
        let close = open + base[open..].find(c)?;
        let inner = fold(&base[open + 1..close]);
        ["soundtrack", "ost", "score", "music", "edition", "deluxe", "remaster", "version", "disc", "cd", "complete"]
            .iter().any(|w| format!(" {inner} ").contains(&format!(" {w} "))).then_some((open, close))
    }) {
        base.replace_range(open..=close, "");
    }
    // Trailing soundtrack words, with whatever separates them.
    let separators = |c: char| c.is_whitespace() || matches!(c, ':' | '-' | '–' | '—' | ',' | '.');
    loop {
        let trimmed = base.trim_end_matches(separators);
        // ASCII lower case keeps byte offsets, so `head` can slice `trimmed`.
        let lower = trimmed.to_ascii_lowercase();
        let head = SOUNDTRACK.iter().find_map(|w| {
            let head = lower.strip_suffix(w)?;
            head.ends_with(|c: char| !c.is_alphanumeric()).then_some(head.len())
        });
        match head {
            Some(len) if !trimmed[..len].trim_end_matches(separators).is_empty() => base = trimmed[..len].to_string(),
            _ => {
                base = trimmed.to_string();
                break;
            }
        }
    }
    let mut out = vec![];
    let mut name = base.trim().to_string();
    while !name.is_empty() {
        if !out.contains(&name) { out.push(name.clone()) }
        let Some(cut) = [" + ", ": ", " - ", " – ", " — "].iter().filter_map(|s| name.rfind(s)).max() else { break };
        name = name[..cut].trim().to_string();
    }
    out
}

/// A name to compare: folded, with roman numerals as digits, so "Ecstatica II" is Ecstatica 2.
pub(crate) fn game_key(name: &str) -> String {
    const ROMAN: [&str; 10] = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"];
    fold(name).split(' ').map(|w| match ROMAN.iter().position(|r| *r == w) {
        Some(i) => (i + 1).to_string(),
        None => w.to_string(),
    }).collect::<Vec<_>>().join(" ")
}

fn names(game: &Game) -> impl Iterator<Item = String> + '_ {
    std::iter::once(&game.title).chain(&game.aliases).map(|n| game_key(n))
}

/// Whether one of the game's composers is among `people`, or named inside one
/// of their credits ("Ada Brennan/Tomas Vey" credits Ada Brennan).
fn shares_composer(game: &Game, people: &[String]) -> bool {
    game.composers.iter().map(|c| format!(" {} ", person(&c.name)))
        .any(|c| people.iter().any(|p| format!(" {p} ").contains(&c)))
}

/// The game `name` names among `games`: an exact name over a prefix of one,
/// and only if it's the only one, or the only one sharing a composer with `people`.
pub(crate) fn choose<'g>(games: &'g [Game], name: &str, people: &[String], needs_composer: bool) -> Option<&'g Game> {
    let key = game_key(name);
    if key.is_empty() { return None }
    let exact: Vec<&Game> = games.iter().filter(|g| names(g).any(|n| n == key)).collect();
    let starts = format!("{key} ");
    let prefix: Vec<&Game> = games.iter().filter(|g| names(g).any(|n| n.starts_with(&starts))).collect();
    for pool in [exact, prefix] {
        let sharing: Vec<&Game> = pool.iter().copied().filter(|g| shares_composer(g, people)).collect();
        let pick = match (pool.len(), sharing.len()) {
            (_, 1) => Some(sharing[0]),
            (1, 0) if !needs_composer => Some(pool[0]),
            _ => None,
        };
        if pick.is_some() || !pool.is_empty() { return pick }
    }
    None
}

/// What a release says about itself, for placing it.
struct Local {
    title: String,
    score: bool,
    /// Its album artists and composers, compared as `person` names.
    people: Vec<String>,
}

fn local(store: &Store, release: i64) -> meret_store::Result<Option<Local>> {
    store.read(|c| {
        let Some((title, idiom)) = c.query_row("SELECT title, idiom FROM release WHERE id = ?1", [release], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?))
        }).optional()? else { return Ok(None) };
        let people: Vec<String> = c.prepare(
            "SELECT DISTINCT a.name FROM credit cr JOIN agent a ON a.id = cr.agent_id
             WHERE (cr.subject_kind = 3 AND cr.subject_id = ?1 AND cr.role = 'album_artist')
                OR (cr.role = 'composer' AND cr.subject_kind = 2 AND cr.subject_id IN (
                    SELECT t.recording_id FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id WHERE e.release_id = ?1))",
        )?.query_map([release], |r| r.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>()?
            .iter().map(|n| person(n)).collect();
        Ok(Some(Local { score: idiom == Some(5) || says_soundtrack(&title), title, people }))
    })
}

/// Searches Wikidata for `release`'s game and records it, if found. The outer
/// error is the request's; the inner, writing what it found.
pub(crate) fn run(core: &Core, ctx: &Context, release: i64) -> Result<meret_store::Result<Vec<NewJob>>, ProviderError> {
    let local = match local(&core.store, release) {
        Ok(Some(local)) => local,
        Ok(None) => return Ok(Ok(vec![])),
        Err(e) => return Ok(Err(e)),
    };
    for name in candidates(&local.title) {
        let games = core.runtime.block_on(provider_wikidata::search_games(ctx, &name))?;
        if let Some(game) = choose(&games, &name, &local.people, !local.score) {
            let placed = place(&core.store, release, game, Context::now_ms());
            if matches!(placed, Ok(true)) { reload(core) }
            return Ok(placed.map(|_| vec![]));
        }
    }
    Ok(Ok(vec![]))
}

/// Writes `game` (by its QID), the release's thread to it, and its composers,
/// and makes the release a score unless its tags or you said what it is.
/// True when that changed its idiom.
pub(crate) fn place(store: &Store, release: i64, game: &Game, now: i64) -> meret_store::Result<bool> {
    let game = game.clone();
    store.writer.write(move |tx| {
        let rev = meret_store::next_rev(tx)?;
        let provenance: i64 = tx.query_row(
            "INSERT INTO provenance (source, external_ref, fetched_at, confidence) VALUES (?1, ?2, ?3, 1.0) RETURNING id",
            params![PROVIDER, game.qid, now], |r| r.get(0),
        )?;
        let known: Option<i64> = tx.query_row(
            "SELECT entity_id FROM external_id WHERE entity_kind = ?1 AND namespace = 'wikidata' AND value = ?2",
            params![EntityKind::Game as i64, game.qid], |r| r.get(0),
        ).optional()?;
        let join = |items: &[String]| (!items.is_empty()).then(|| items.join(", "));
        let fields = params![game.title, game.year, join(&game.developers), join(&game.platforms),
            game.series.as_ref().map(|s| &s.name), game.series.as_ref().map(|s| &s.qid), rev];
        let id: i64 = match known {
            Some(id) => {
                tx.execute(
                    "UPDATE game SET title = ?1, year = ?2, developers = ?3, platforms = ?4, series = ?5, series_ref = ?6, rev = ?7 WHERE id = ?8",
                    rusqlite::params_from_iter(fields.iter().copied().chain([&id as &dyn rusqlite::ToSql])),
                )?;
                id
            }
            None => {
                let id = tx.query_row(
                    "INSERT INTO game (title, year, developers, platforms, series, series_ref, rev) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) RETURNING id",
                    fields, |r| r.get(0),
                )?;
                tx.execute(
                    "INSERT INTO external_id (entity_kind, entity_id, namespace, value, provenance_id) VALUES (?1, ?2, 'wikidata', ?3, ?4)",
                    params![EntityKind::Game as i64, id, game.qid, provenance],
                )?;
                id
            }
        };
        tx.execute(
            "INSERT OR IGNORE INTO edge (from_kind, from_id, to_kind, to_id, kind, provenance_id, rev) VALUES (3, ?1, ?2, ?3, 'soundtrack_of', ?4, ?5)",
            params![release, EntityKind::Game as i64, id, provenance, rev],
        )?;
        for (sort, composer) in game.composers.iter().enumerate() {
            let agent = agent(tx, release, &composer.qid, &composer.name, rev, provenance)?;
            tx.execute(
                "INSERT INTO credit (subject_kind, subject_id, agent_id, role, sort, provenance_id, rev)
                 SELECT ?1, ?2, ?3, 'composer', ?4, ?5, ?6 WHERE NOT EXISTS (
                    SELECT 1 FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND agent_id = ?3 AND role = 'composer')",
                params![EntityKind::Game as i64, id, agent, sort as i64, provenance, rev],
            )?;
        }
        let rescored = tx.execute(
            "UPDATE release SET idiom = ?2, idiom_source = ?3, rev = ?4
             WHERE id = ?1 AND (idiom IS NULL OR idiom_source IS NULL OR idiom_source = ?5) AND idiom IS NOT ?2",
            params![release, Idiom::Score as u8, idiom::GAME, rev, idiom::DEFAULT],
        )?;
        Ok(rescored > 0)
    })
}

/// Reloads the hot columns after a release changed idiom, so tables and facets regroup it.
fn reload(core: &Core) {
    match core.store.load_columns() {
        Ok(cols) => {
            let tracks = cols.len() as u64;
            *core.columns.write() = cols;
            core.status.send_modify(|s| crate::status::set_library(s, tracks));
        }
        Err(e) => tracing::error!(error = %e, "could not reload the library after placing a score"),
    }
}

/// The person a Wikidata QID names: the one with that QID; else one of that
/// name without one, credited on the release when there is one; else a new
/// person, reachable by threads only.
fn agent(tx: &Transaction<'_>, release: i64, qid: &str, name: &str, rev: i64, provenance: i64) -> rusqlite::Result<i64> {
    if let Some(id) = tx.query_row(
        "SELECT entity_id FROM external_id WHERE entity_kind = 6 AND namespace = 'wikidata' AND value = ?1", [qid], |r| r.get(0),
    ).optional()? {
        return Ok(id);
    }
    let unnamed = "NOT EXISTS (SELECT 1 FROM external_id x WHERE x.entity_kind = 6 AND x.entity_id = a.id AND x.namespace = 'wikidata')";
    let key = name_key(name);
    let on_release: Option<i64> = tx.query_row(
        &format!("SELECT a.id FROM agent a WHERE a.normalized_name = ?1 AND {unnamed} AND a.id IN (
            SELECT cr.agent_id FROM credit cr WHERE (cr.subject_kind = 3 AND cr.subject_id = ?2) OR (cr.subject_kind = 2 AND cr.subject_id IN (
                SELECT t.recording_id FROM edition e JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id WHERE e.release_id = ?2)))
            ORDER BY a.id LIMIT 1"),
        params![key, release], |r| r.get(0),
    ).optional()?;
    let id = match on_release {
        Some(id) => id,
        None => match tx.query_row(
            &format!("SELECT a.id FROM agent a WHERE a.normalized_name = ?1 AND {unnamed} ORDER BY a.id LIMIT 1"), [&key], |r| r.get(0),
        ).optional()? {
            Some(id) => id,
            None => tx.query_row(
                "INSERT INTO agent (kind, name, normalized_name, rev) VALUES (0, ?1, ?2, ?3) RETURNING id",
                params![clean_name(name), key, rev], |r| r.get(0),
            )?,
        },
    };
    tx.execute(
        "INSERT OR IGNORE INTO external_id (entity_kind, entity_id, namespace, value, provenance_id) VALUES (6, ?1, 'wikidata', ?2, ?3)",
        params![id, qid, provenance],
    )?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use provider_wikidata::Named;

    fn game(qid: &str, title: &str, aliases: &[&str], composers: &[&str]) -> Game {
        Game {
            qid: qid.into(), title: title.into(), aliases: aliases.iter().map(|a| a.to_string()).collect(), year: Some(2001),
            composers: composers.iter().enumerate().map(|(i, c)| Named { qid: format!("Qc{i}"), name: c.to_string() }).collect(),
            developers: vec![], platforms: vec![], series: None,
        }
    }

    #[test]
    fn titles_lose_their_soundtrack_words_then_their_last_part() {
        assert_eq!(candidates("Tyranny Official Soundtrack (Deluxe Edition)"), ["Tyranny"]);
        assert_eq!(candidates("Fixture Quest: Ost"), ["Fixture Quest"]);
        assert_eq!(candidates("Fixture Quest 2 O.S.T."), ["Fixture Quest 2"]);
        assert_eq!(candidates("Sid Meier's Fixture V (Original Game Soundtrack)"), ["Sid Meier's Fixture V"]);
        assert_eq!(candidates("Fixture II: Total War + Kingdoms (Original Soundtrack)"), ["Fixture II: Total War + Kingdoms", "Fixture II: Total War", "Fixture II"]);
        assert_eq!(candidates("Musicology"), ["Musicology"], "a word that only ends like one stays");
    }

    #[test]
    fn an_exact_name_wins_and_ties_need_a_shared_composer() {
        let games = [
            game("Q1", "Fixture Quest II", &[], &["Ada Brennan"]),
            game("Q2", "Fixture Quest II: Second Wind", &["Fixture Quest 2: Second Wind"], &[]),
        ];
        assert_eq!(choose(&games, "Fixture Quest 2", &[], false).map(|g| g.qid.as_str()), Some("Q1"), "roman numerals as digits");
        let sequels = [game("Q2", "Fixture Saga: Second Wind", &[], &[]), game("Q3", "Fixture Saga: Third Wind", &[], &["Ada Brennan"])];
        assert_eq!(choose(&sequels, "Fixture Saga", &[], false), None, "two prefixes, no composer");
        assert_eq!(choose(&sequels, "Fixture Saga", &[person("Ada M. Brennan")], false).map(|g| g.qid.as_str()), Some("Q3"));
        let one = [game("Q4", "Fixture Saga: Birth of a Legend", &[], &[])];
        assert_eq!(choose(&one, "Fixture Saga", &[], false).map(|g| g.qid.as_str()), Some("Q4"));
        assert_eq!(choose(&one, "Fixture Saga", &[], true), None, "an album needs a shared composer");
        let scored = [game("Q5", "Fixture Saga", &[], &["Ada Brennan"])];
        assert!(choose(&scored, "Fixture Saga", &[person("Ada Brennan/Tomas Vey")], true).is_some(), "a joined credit names her");
    }
}

#[cfg(test)]
mod place_tests {
    use super::*;
    use provider_wikidata::Named;

    #[test]
    fn placing_a_release_makes_it_a_score_unless_its_tags_said_otherwise() {
        let dir = std::env::temp_dir().join(format!("meret-games-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| tx.execute_batch(
            "INSERT INTO release (id, title, idiom, idiom_source, rev) VALUES
                (1, 'Fixture Quest', 1, 'default', 1), (2, 'Fixture Quest Live', 1, 'tags', 1);")).unwrap();
        let game = Game {
            qid: "Q1".into(), title: "Fixture Quest".into(), aliases: vec![], year: Some(2001),
            composers: vec![Named { qid: "Q2".into(), name: "Ada Brennan".into() }],
            developers: vec!["Fixture Works".into()], platforms: vec![], series: None,
        };
        assert!(place(&store, 1, &game, 1).unwrap());
        assert!(!place(&store, 1, &game, 2).unwrap(), "already a score");
        assert!(!place(&store, 2, &game, 3).unwrap());
        let idioms: Vec<(i64, String)> = store.read(|c| c.prepare("SELECT idiom, idiom_source FROM release ORDER BY id")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect()).unwrap();
        assert_eq!(idioms, [(5, "game".to_string()), (1, "tags".to_string())]);
        let games: i64 = store.read(|c| c.query_row("SELECT COUNT(*) FROM game", [], |r| r.get(0))).unwrap();
        assert_eq!(games, 1, "one game however many soundtracks");
        drop(store);
        std::fs::remove_dir_all(dir).ok();
    }
}
