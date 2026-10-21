//! What a release pane and a person pane show. Only tracks with a present
//! file count, as everywhere else, so a pane matches the table.
//!
//! People are found through `credit_agent` and tracks through
//! `track_recording`, so a page costs reads proportional to what's on it,
//! not to the library.

use std::collections::HashMap;

use meret_model::{AgentId, Idiom, ReleaseId, TrackId, WorkId};
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
    /// Everyone else credited on its tracks (composers, arrangers,
    /// performers…), by role in `ROLES` order, then first appearance.
    pub roles: Vec<RoleCredit>,
    /// The work each track is a recording of, for tracks that say.
    pub works: Vec<(TrackId, WorkId, String)>,
    /// Counted plays of this release, and the newest one.
    pub plays: u64,
    pub last_played: Option<i64>,
}

/// One person in one role across a release's tracks.
#[derive(Clone, Debug, PartialEq)]
pub struct RoleCredit {
    /// As `credit.role`: composer, arranger, lyricist, performer, conductor,
    /// producer, engineer.
    pub role: String,
    pub agent: AgentId,
    pub name: String,
    /// What they play, for performers: "percussion", "shakuhachi".
    pub detail: Option<String>,
    /// (disc, track) of each track they're credited on.
    pub positions: Vec<(u32, u32)>,
}

/// Credit roles besides artist and album artist, in the order panes show them.
pub const ROLES: [&str; 7] = ["composer", "lyricist", "arranger", "performer", "conductor", "producer", "engineer"];

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
    /// Releases they're credited on in another role, per role in `ROLES`
    /// order, by year.
    pub roles: Vec<(String, Vec<PersonRelease>)>,
    /// Works they wrote, by title, with how many of your tracks record each.
    pub works: Vec<PersonWork>,
    /// People who share releases with them, most shared first.
    pub worked_with: Vec<Colleague>,
    /// Counted plays of their recordings and the releases they front.
    pub plays: u64,
    pub last_played: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PersonWork {
    pub work: WorkId,
    pub title: String,
    pub tracks: u32,
}

/// A work pane: a composition and every recording of it you have.
#[derive(Clone, Debug, PartialEq)]
pub struct WorkPage {
    pub work: WorkId,
    pub title: String,
    /// The composer as written, from the work or the work it's part of.
    pub composer: Option<String>,
    pub composers: Vec<(AgentId, String)>,
    /// The work this is a movement or part of.
    pub parent: Option<(WorkId, String)>,
    /// Its movements or parts, in order, with how many tracks record each.
    pub parts: Vec<PersonWork>,
    /// Present recordings of it and its parts, release by release.
    pub tracks: Vec<TrackRow>,
    pub plays: u64,
    pub last_played: Option<i64>,
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
        let mut roles: Vec<RoleCredit> = vec![];
        let mut works = vec![];
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
            let sql = format!(
                "SELECT cr.role, a.id, a.name, cr.detail, m.position, t.position FROM track t
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 JOIN credit cr ON cr.subject_kind = 2 AND cr.subject_id = t.recording_id AND cr.role <> 'artist'
                 JOIN agent a ON a.id = cr.agent_id
                 WHERE e.release_id = ?1 AND {PREFERRED_SOURCE} IS NOT NULL ORDER BY m.position, t.position, t.id, cr.sort, cr.id"
            );
            for row in c.prepare(&sql)?.query_map([release.0], |r| {
                Ok((r.get::<_, String>(0)?, AgentId(r.get(1)?), r.get::<_, String>(2)?, r.get::<_, Option<String>>(3)?,
                    (r.get::<_, u32>(4)?, r.get::<_, u32>(5)?)))
            })? {
                let (role, agent, name, detail, position) = row?;
                // "orchestration" on two tracks is said of those two, not of every track they arranged.
                match roles.iter_mut().find(|c: &&mut RoleCredit| c.role == role && c.agent == agent && c.detail == detail) {
                    Some(c) => if !c.positions.contains(&position) { c.positions.push(position) },
                    None => roles.push(RoleCredit { role, agent, name, detail, positions: vec![position] }),
                }
            }
            let sql = format!(
                "SELECT t.id, w.id, w.title FROM track t
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 JOIN recording r ON r.id = t.recording_id JOIN work w ON w.id = r.work_id
                 WHERE e.release_id = ?1 AND {PREFERRED_SOURCE} IS NOT NULL ORDER BY m.position, t.position, t.id"
            );
            works = c.prepare(&sql)?.query_map([release.0], |r| Ok((TrackId(r.get(0)?), WorkId(r.get(1)?), r.get(2)?)))?
                .collect::<rusqlite::Result<_>>()?;
            Ok(())
        })?;
        // Stable: within a role, people stay in order of first appearance.
        roles.sort_by_key(|c| ROLES.iter().position(|r| *r == c.role).unwrap_or(ROLES.len()));
        let cover = self.release_art(&[release])?.remove(&release);
        let (plays, last_played) = self.release_plays(release)?;
        Ok(Some(ReleasePage { release, title, year, idiom, album_artist, album_artists, cover, tracks, artists, roles, works, plays, last_played }))
    }

    /// None when the person doesn't exist.
    pub fn person_page(&self, agent: AgentId) -> Result<Option<PersonPage>> {
        let (plays, last_played) = self.person_plays(agent)?;
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


            let sql = format!(
                "SELECT c.role, e.release_id, COUNT(DISTINCT t.id) FROM credit c
                 JOIN track t ON t.recording_id = c.subject_id
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 WHERE c.agent_id = ?1 AND c.role <> 'artist' AND c.subject_kind = 2 AND {PREFERRED_SOURCE} IS NOT NULL
                 GROUP BY c.role, e.release_id"
            );
            let mut roles: Vec<(String, Vec<PersonRelease>)> = vec![];
            for row in c.prepare(&sql)?.query_map([agent.0], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, u32>(2)?)))? {
                let (role, id, theirs) = row?;
                let (title, year, tracks) = release_summary(c, id)?;
                let r = PersonRelease { release: ReleaseId(id), title, year, theirs, tracks };
                match roles.iter_mut().find(|(name, _)| *name == role) {
                    Some((_, list)) => list.push(r),
                    None => roles.push((role, vec![r])),
                }
            }
            roles.sort_by_key(|(role, _)| ROLES.iter().position(|r| r == role).unwrap_or(ROLES.len()));
            for list in [&mut releases, &mut appears_on].into_iter().chain(roles.iter_mut().map(|(_, list)| list)) {
                list.sort_by(|a, b| {
                    (a.year.is_none(), a.year, a.title.to_lowercase()).cmp(&(b.year.is_none(), b.year, b.title.to_lowercase()))
                });
            }

            let sql = format!(
                "SELECT w.id, w.title, (SELECT COUNT(*) FROM recording r JOIN track t ON t.recording_id = r.id
                     JOIN work x ON x.id = r.work_id WHERE (x.id = w.id OR x.parent_id = w.id) AND {PREFERRED_SOURCE} IS NOT NULL) AS n
                 FROM credit c JOIN work w ON w.id = c.subject_id
                 WHERE c.subject_kind = 1 AND c.role = 'composer' AND c.agent_id = ?1 AND n > 0
                 ORDER BY w.title COLLATE NOCASE"
            );
            let works = c.prepare(&sql)?
                .query_map([agent.0], |r| Ok(PersonWork { work: WorkId(r.get(0)?), title: r.get(1)?, tracks: r.get(2)? }))?
                .collect::<rusqlite::Result<Vec<_>>>()?;

            let mut on: Vec<ReleaseId> = releases.iter().chain(&appears_on).chain(roles.iter().flat_map(|(_, l)| l)).map(|r| r.release).collect();
            on.sort_unstable_by_key(|r| r.0);
            on.dedup();
            let mut shared: HashMap<i64, u32> = HashMap::new();
            for release in on {
                for other in release_people(c, release.0)? {
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

            // Every present track they're on: their releases', any credit on
            // a recording, and recordings of works they wrote.
            let sql = format!(
                "SELECT COUNT(*) FROM track t WHERE {PREFERRED_SOURCE} IS NOT NULL AND (
                     EXISTS (SELECT 1 FROM credit c WHERE c.subject_kind = 2 AND c.subject_id = t.recording_id AND c.agent_id = ?1)
                  OR EXISTS (SELECT 1 FROM medium m JOIN edition e ON e.id = m.edition_id JOIN credit c
                         ON c.subject_kind = 3 AND c.subject_id = e.release_id AND c.role = 'album_artist'
                         WHERE m.id = t.medium_id AND c.agent_id = ?1)
                  OR EXISTS (SELECT 1 FROM recording r JOIN work w ON w.id = r.work_id JOIN credit c
                         ON c.subject_kind = 1 AND c.subject_id IN (w.id, w.parent_id) AND c.role = 'composer'
                         WHERE r.id = t.recording_id AND c.agent_id = ?1))"
            );
            let tracks = c.query_row(&sql, [agent.0], |r| r.get(0))?;
            Ok(Some(PersonPage { agent, name, tracks, releases, appears_on, roles, works, worked_with, plays, last_played }))
        })
    }

    /// None when the work doesn't exist.
    pub fn work_page(&self, work: WorkId) -> Result<Option<WorkPage>> {
        let found = self.read(|c| {
            let Some((title, parent_id, own_credit)) = c
                .query_row("SELECT title, parent_id, composer_credit FROM work WHERE id = ?1", [work.0], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?, r.get::<_, Option<String>>(2)?))
                })
                .optional()?
            else {
                return Ok(None);
            };
            let parent = match parent_id {
                Some(id) => Some((WorkId(id), c.query_row("SELECT title FROM work WHERE id = ?1", [id], |r| r.get::<_, String>(0))?)),
                None => None,
            };
            // A movement's composer is its work's.
            let top = parent_id.unwrap_or(work.0);
            let composer = match parent_id {
                Some(id) => c.query_row("SELECT composer_credit FROM work WHERE id = ?1", [id], |r| r.get(0))?,
                None => own_credit,
            };
            let composers = c.prepare(
                "SELECT DISTINCT a.id, a.name FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 1 AND c.subject_id = ?1 AND c.role = 'composer' ORDER BY c.sort, c.id"
            )?.query_map([top], |r| Ok((AgentId(r.get(0)?), r.get(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
            let sql = format!(
                "SELECT w.id, w.title, (SELECT COUNT(*) FROM recording r JOIN track t ON t.recording_id = r.id
                     WHERE r.work_id = w.id AND {PREFERRED_SOURCE} IS NOT NULL)
                 FROM work w WHERE w.parent_id = ?1 ORDER BY w.position IS NULL, w.position, w.title COLLATE NOCASE"
            );
            let parts = c.prepare(&sql)?
                .query_map([work.0], |r| Ok(PersonWork { work: WorkId(r.get(0)?), title: r.get(1)?, tracks: r.get(2)? }))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let sql = format!(
                "SELECT t.id FROM track t JOIN recording r ON r.id = t.recording_id JOIN work w ON w.id = r.work_id
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id JOIN release rl ON rl.id = e.release_id
                 WHERE (w.id = ?1 OR w.parent_id = ?1) AND {PREFERRED_SOURCE} IS NOT NULL
                 ORDER BY rl.year IS NULL, rl.year, rl.title COLLATE NOCASE, rl.id, m.position, t.position, t.id"
            );
            let tracks = c.prepare(&sql)?.query_map([work.0], |r| Ok(TrackId(r.get(0)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
            let (plays, last_played) = c.query_row(
                &format!(
                    "SELECT COUNT(*), MAX(l.started_at) FROM listen l JOIN recording r ON r.id = l.recording_id
                     JOIN work w ON w.id = r.work_id
                     LEFT JOIN track t ON t.id = (SELECT MIN(id) FROM track WHERE recording_id = r.id)
                     WHERE (w.id = ?1 OR w.parent_id = ?1) AND {COUNTED}",
                    COUNTED = crate::listens::COUNTED
                ),
                [work.0],
                |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, Option<i64>>(1)?)),
            )?;
            Ok(Some((title, composer, composers, parent, parts, tracks, plays, last_played)))
        })?;
        let Some((title, composer, composers, parent, parts, tracks, plays, last_played)) = found else { return Ok(None) };
        let tracks = self.track_rows(&tracks)?;
        Ok(Some(WorkPage { work, title, composer, composers, parent, parts, tracks, plays, last_played }))
    }

    /// A work's title, for naming a trail stop.
    pub fn work_title(&self, work: WorkId) -> Result<Option<String>> {
        self.read(|c| c.query_row("SELECT title FROM work WHERE id = ?1", [work.0], |r| r.get(0)).optional())
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

/// Everyone credited on a release: its album artist and anyone credited on
/// its present tracks, in any role.
fn release_people(c: &Connection, release: i64) -> rusqlite::Result<Vec<i64>> {
    let sql = format!(
        "SELECT agent_id FROM credit WHERE subject_kind = 3 AND subject_id = ?1 AND role = 'album_artist'
         UNION
         SELECT c.agent_id FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
         JOIN credit c ON c.subject_kind = 2 AND c.subject_id = t.recording_id
         WHERE e.release_id = ?1 AND {PREFERRED_SOURCE} IS NOT NULL"
    );
    c.prepare_cached(&sql)?.query_map([release], |r| r.get(0))?.collect()
}
