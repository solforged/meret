//! What a release pane and a person pane show. Only tracks with a present
//! file count, as everywhere else, so a pane matches the table.
//!
//! People are found through `credit_agent` and tracks through
//! `track_recording`, so a page costs reads proportional to what's on it,
//! not to the library.

use std::collections::HashMap;

use meret_model::{AgentId, Idiom, ReleaseId, TrackId};
use rusqlite::{Connection, OptionalExtension};

use crate::library::{PREFERRED_SOURCE, TrackRow};
use crate::{Artwork, Result, Store};

/// A release pane.
#[derive(Clone, Debug, PartialEq)]
pub struct ReleasePage {
    pub release: ReleaseId,
    pub title: String,
    pub year: Option<u16>,
    pub idiom: Option<Idiom>,
    pub album_artist: Option<(AgentId, String)>,
    /// All album artists as individual thread targets, in written order.
    pub album_artists: Vec<(AgentId, String)>,
    pub cover: Option<Artwork>,
    /// Present tracks, in disc and track order.
    pub tracks: Vec<TrackRow>,
    /// Track artists in order of first appearance, with the tracks they're on.
    pub artists: Vec<TrackCredit>,
}

/// One artist on a release, and where.
#[derive(Clone, Debug, PartialEq)]
pub struct TrackCredit {
    pub agent: AgentId,
    pub name: String,
    /// (disc, track) of each track they're credited on.
    pub positions: Vec<(u32, u32)>,
}

/// A person pane. "Person" covers groups too.
#[derive(Clone, Debug, PartialEq)]
pub struct PersonPage {
    pub agent: AgentId,
    pub name: String,
    /// Their present tracks: all of their own releases', and theirs on
    /// other people's.
    pub tracks: u32,
    /// Releases they're the album artist of, by year.
    pub releases: Vec<PersonRelease>,
    /// Other people's releases they're on, by year.
    pub appears_on: Vec<PersonRelease>,
    /// People who share releases with them, most shared first.
    pub worked_with: Vec<Colleague>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PersonRelease {
    pub release: ReleaseId,
    pub title: String,
    pub year: Option<u16>,
    /// Their tracks on it.
    pub theirs: u32,
    /// All its present tracks.
    pub tracks: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Colleague {
    pub agent: AgentId,
    pub name: String,
    /// Releases they share.
    pub releases: u32,
}

/// How many people a person pane lists under "worked with".
const COLLEAGUES: usize = 12;

impl Store {
    /// None when the release doesn't exist.
    pub fn release_page(&self, release: ReleaseId) -> Result<Option<ReleasePage>> {
        let found = self.read(|c| {
            let Some((title, year, idiom)) = c
                .query_row("SELECT title, year, idiom FROM release WHERE id = ?1", [release.0], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Option<u16>>(1)?, r.get::<_, Option<u8>>(2)?))
                })
                .optional()?
            else {
                return Ok(None);
            };
            let album_artist = c
                .query_row(
                    "SELECT a.id, a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                     WHERE c.subject_kind = 3 AND c.subject_id = ?1 AND c.role = 'album_artist' ORDER BY c.sort LIMIT 1",
                    [release.0],
                    |r| Ok((AgentId(r.get(0)?), r.get::<_, String>(1)?)),
                )
                .optional()?;
            let album_artists = c.prepare(
                "SELECT DISTINCT a.id, a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 3 AND c.subject_id = ?1 AND c.role = 'album_artist' ORDER BY c.sort, c.id"
            )?.query_map([release.0], |r| Ok((AgentId(r.get(0)?), r.get(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
            let album_artist = match album_artist {
                Some((id, name)) => Some((id, c.query_row(
                    "SELECT COALESCE(album_artist_credit, ?2) FROM release WHERE id = ?1", (release.0, name), |r| r.get(0))?)),
                None => None,
            };
            let sql = format!(
                "SELECT t.id FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 WHERE e.release_id = ?1 AND {PREFERRED_SOURCE} IS NOT NULL ORDER BY m.position, t.position, t.id"
            );
            let tracks = c
                .prepare(&sql)?
                .query_map([release.0], |r| Ok(TrackId(r.get(0)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let idiom = idiom.and_then(|v| Idiom::ALL.into_iter().find(|i| *i as u8 == v));
            Ok(Some((title, year, idiom, album_artist, album_artists, tracks)))
        })?;
        let Some((title, year, idiom, album_artist, album_artists, tracks)) = found else { return Ok(None) };
        let tracks = self.track_rows(&tracks)?;
        let mut artists: Vec<TrackCredit> = vec![];
        self.read(|c| {
            let sql = format!(
                "SELECT a.id, a.name, m.position, t.position FROM track t
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 JOIN credit cr ON cr.subject_kind = 2 AND cr.subject_id = t.recording_id AND cr.role = 'artist'
                 JOIN agent a ON a.id = cr.agent_id
                 WHERE e.release_id = ?1 AND {PREFERRED_SOURCE} IS NOT NULL ORDER BY m.position, t.position, t.id, cr.sort, cr.id"
            );
            for row in c.prepare(&sql)?.query_map([release.0], |r| {
                Ok((AgentId(r.get(0)?), r.get::<_, String>(1)?, (r.get::<_, u32>(2)?, r.get::<_, u32>(3)?)))
            })? {
                let (agent, name, position) = row?;
                match artists.iter_mut().find(|a| a.agent == agent) {
                    Some(a) => { if !a.positions.contains(&position) { a.positions.push(position); } }
                    None => artists.push(TrackCredit { agent, name, positions: vec![position] }),
                }
            }
            Ok(())
        })?;
        let cover = self.release_art(&[release])?.remove(&release);
        Ok(Some(ReleasePage { release, title, year, idiom, album_artist, album_artists, cover, tracks, artists }))
    }

    /// None when the person doesn't exist.
    pub fn person_page(&self, agent: AgentId) -> Result<Option<PersonPage>> {
        self.read(|c| {
            let Some(name) =
                c.query_row("SELECT name FROM agent WHERE id = ?1", [agent.0], |r| r.get::<_, String>(0)).optional()?
            else {
                return Ok(None);
            };
            let fronted: Vec<i64> = c
                .prepare("SELECT DISTINCT subject_id FROM credit WHERE agent_id = ?1 AND role = 'album_artist' AND subject_kind = 3")?
                .query_map([agent.0], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            let sql = format!(
                "SELECT e.release_id, COUNT(DISTINCT t.id) FROM credit c
                 JOIN track t ON t.recording_id = c.subject_id
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 WHERE c.agent_id = ?1 AND c.role = 'artist' AND c.subject_kind = 2 AND {PREFERRED_SOURCE} IS NOT NULL
                 GROUP BY e.release_id"
            );
            let theirs: HashMap<i64, u32> =
                c.prepare(&sql)?.query_map([agent.0], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?;

            let mut releases = vec![];
            let mut appears_on = vec![];
            let mut ids: Vec<i64> = fronted.iter().copied().chain(theirs.keys().copied()).collect();
            ids.sort_unstable();
            ids.dedup();
            for id in ids {
                let (title, year, tracks) = release_summary(c, id)?;
                if tracks == 0 {
                    continue;
                }
                let r = PersonRelease { release: ReleaseId(id), title, year, theirs: theirs.get(&id).copied().unwrap_or(0), tracks };
                if fronted.contains(&id) { releases.push(r) } else { appears_on.push(r) }
            }
            for list in [&mut releases, &mut appears_on] {
                list.sort_by(|a, b| {
                    (a.year.is_none(), a.year, a.title.to_lowercase()).cmp(&(b.year.is_none(), b.year, b.title.to_lowercase()))
                });
            }

            let mut shared: HashMap<i64, u32> = HashMap::new();
            for r in releases.iter().chain(&appears_on) {
                for other in release_people(c, r.release.0)? {
                    if other != agent.0 {
                        *shared.entry(other).or_default() += 1;
                    }
                }
            }
            let mut worked_with = shared
                .into_iter()
                .map(|(id, releases)| {
                    let name = c.query_row("SELECT name FROM agent WHERE id = ?1", [id], |r| r.get::<_, String>(0))?;
                    Ok(Colleague { agent: AgentId(id), name, releases })
                })
                .collect::<rusqlite::Result<Vec<_>>>()?;
            worked_with.sort_by(|a, b| b.releases.cmp(&a.releases).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
            worked_with.truncate(COLLEAGUES);

            let tracks = releases.iter().map(|r| r.tracks).sum::<u32>() + appears_on.iter().map(|r| r.theirs).sum::<u32>();
            Ok(Some(PersonPage { agent, name, tracks, releases, appears_on, worked_with }))
        })
    }

    /// A release's title, for naming a trail stop.
    pub fn release_title(&self, release: ReleaseId) -> Result<Option<String>> {
        self.read(|c| c.query_row("SELECT title FROM release WHERE id = ?1", [release.0], |r| r.get(0)).optional())
    }

    /// A person's name, for naming a trail stop.
    pub fn agent_name(&self, agent: AgentId) -> Result<Option<String>> {
        self.read(|c| c.query_row("SELECT name FROM agent WHERE id = ?1", [agent.0], |r| r.get(0)).optional())
    }
}

/// Title, year and present track count.
fn release_summary(c: &Connection, release: i64) -> rusqlite::Result<(String, Option<u16>, u32)> {
    let sql = format!(
        "SELECT rl.title, rl.year,
                (SELECT COUNT(*) FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 WHERE e.release_id = rl.id AND {PREFERRED_SOURCE} IS NOT NULL)
         FROM release rl WHERE rl.id = ?1"
    );
    c.prepare_cached(&sql)?.query_row([release], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
}

/// Everyone credited on a release: its album artist and its present tracks' artists.
fn release_people(c: &Connection, release: i64) -> rusqlite::Result<Vec<i64>> {
    let sql = format!(
        "SELECT agent_id FROM credit WHERE subject_kind = 3 AND subject_id = ?1 AND role = 'album_artist'
         UNION
         SELECT c.agent_id FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
         JOIN credit c ON c.subject_kind = 2 AND c.subject_id = t.recording_id AND c.role = 'artist'
         WHERE e.release_id = ?1 AND {PREFERRED_SOURCE} IS NOT NULL"
    );
    c.prepare_cached(&sql)?.query_map([release], |r| r.get(0))?.collect()
}
