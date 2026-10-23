//! What a release pane and a person pane show. Only tracks with a present
//! file count, as everywhere else, so a pane matches the table.
//!
//! People are found through `credit_agent` and tracks through
//! `track_recording`, so a page costs reads proportional to what's on it,
//! not to the library.

use std::collections::HashMap;

use meret_model::{AgentId, GameId, Idiom, RecordingId, ReleaseId, TrackId, WorkId};
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
    /// Games this release is a soundtrack of.
    pub games: Vec<GameLink>,
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
    pub source: String,
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
    /// Games crediting them, by year.
    pub games: Vec<GameLink>,
    /// People who share releases with them, most shared first.
    pub worked_with: Vec<Colleague>,
    pub member_of: Vec<PersonLink>,
    pub members: Vec<PersonLink>,
    pub linked: Vec<PersonLink>,
    /// Counted plays of their recordings and the releases they front.
    pub plays: u64,
    pub last_played: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PersonLink {
    pub agent: AgentId,
    pub name: String,
    pub detail: Option<String>,
    pub source: String,
    pub tracks: u64,
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
    pub others: Vec<OtherRecording>,
    pub recordings_known: Option<u64>,
    pub plays: u64,
    pub last_played: Option<i64>,
}

/// A game pane: the game a score belongs to, and its soundtracks you have.
#[derive(Clone, Debug, PartialEq)]
pub struct GamePage {
    pub game: GameId,
    pub title: String,
    pub year: Option<u16>,
    pub developers: Option<String>,
    pub platforms: Option<String>,
    pub series: Option<String>,
    /// Releases linked by `soundtrack_of`, by year then title; tracks = present tracks.
    pub soundtracks: Vec<PersonRelease>,
    /// Composers in credit sort order; tracks = their present tracks in any role.
    pub composers: Vec<PersonLink>,
    /// Other games in the same series with a soundtrack you have, by year.
    pub same_series: Vec<GameLink>,
    /// Present soundtrack tracks, in release order then disc and track order.
    pub tracks: Vec<TrackRow>,
    pub plays: u64,
    pub last_played: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GameLink {
    pub game: GameId,
    pub title: String,
    pub year: Option<u16>,
    pub source: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct OtherRecording {
    pub recording: RecordingId,
    pub title: String,
    pub length_ms: Option<u64>,
    pub artists: Vec<(AgentId, String)>,
    pub source: String,
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
        let mut games = vec![];
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
                "SELECT cr.role, a.id, a.name, cr.detail, m.position, t.position, COALESCE(p.source, 'local_tags') FROM track t
                 JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                 JOIN credit cr ON cr.subject_kind = 2 AND cr.subject_id = t.recording_id AND cr.role <> 'artist'
                 JOIN agent a ON a.id = cr.agent_id
                 LEFT JOIN provenance p ON p.id = cr.provenance_id
                 WHERE e.release_id = ?1 AND {PREFERRED_SOURCE} IS NOT NULL ORDER BY m.position, t.position, t.id, cr.sort, cr.id"
            );
            for row in c.prepare(&sql)?.query_map([release.0], |r| {
                Ok((r.get::<_, String>(0)?, AgentId(r.get(1)?), r.get::<_, String>(2)?, r.get::<_, Option<String>>(3)?,
                    (r.get::<_, u32>(4)?, r.get::<_, u32>(5)?), r.get::<_, String>(6)?))
            })? {
                let (role, agent, name, detail, position, source) = row?;
                // "orchestration" on two tracks is said of those two, not of every track they arranged.
                match roles.iter_mut().find(|c: &&mut RoleCredit| c.role == role && c.agent == agent && c.detail == detail) {
                    Some(c) => if !c.positions.contains(&position) { c.positions.push(position) },
                    None => roles.push(RoleCredit { role, agent, name, detail, source, positions: vec![position] }),
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
            games = c.prepare(
                "SELECT g.id, g.title, g.year, COALESCE(p.source, 'local_tags')
                 FROM edge e JOIN game g ON g.id = e.to_id LEFT JOIN provenance p ON p.id = e.provenance_id
                 WHERE e.from_kind = 3 AND e.from_id = ?1 AND e.to_kind = 13 AND e.kind = 'soundtrack_of'
                 ORDER BY g.year IS NULL, g.year, g.title COLLATE NOCASE, g.id, e.id"
            )?.query_map([release.0], game_link)?.collect::<rusqlite::Result<_>>()?;
            Ok(())
        })?;
        // Stable: within a role, people stay in order of first appearance.
        roles.sort_by_key(|c| ROLES.iter().position(|r| *r == c.role).unwrap_or(ROLES.len()));
        let cover = self.release_art(&[release])?.remove(&release);
        let (plays, last_played) = self.release_plays(release)?;
        Ok(Some(ReleasePage { release, title, year, idiom, album_artist, album_artists, cover, tracks, artists, roles, works, games, plays, last_played }))
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
            let games = c.prepare(
                "SELECT DISTINCT g.id, g.title, g.year, COALESCE(p.source, 'local_tags')
                 FROM credit cr JOIN game g ON g.id = cr.subject_id LEFT JOIN provenance p ON p.id = cr.provenance_id
                 WHERE cr.subject_kind = 13 AND cr.agent_id = ?1
                 ORDER BY g.year IS NULL, g.year, g.title COLLATE NOCASE, g.id"
            )?.query_map([agent.0], game_link)?.collect::<rusqlite::Result<_>>()?;

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

            let tracks = person_tracks(c, agent)?;
            let member_of = person_links(c, agent, "member_of", true)?;
            let members = person_links(c, agent, "member_of", false)?;
            let linked = person_links(c, agent, "worked_with", true)?;
            Ok(Some(PersonPage { agent, name, tracks: tracks as u32, releases, appears_on, roles, works, games, worked_with,
                member_of, members, linked, plays, last_played }))
        })
    }

    /// None when the work doesn't exist.
    pub fn work_page(&self, work: WorkId) -> Result<Option<WorkPage>> {
        let found = self.read(|c| {
            let Some((title, parent_id, own_credit, recordings_known)) = c
                .query_row("SELECT title, parent_id, composer_credit, recording_count FROM work WHERE id = ?1", [work.0], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, Option<i64>>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, Option<i64>>(3)?.map(|n| n as u64)))
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
            let mut others = c.prepare(
                "SELECT r.id, r.title, r.length_ms, COALESCE(
                     (SELECT COALESCE(p.source, 'local_tags') FROM credit cr LEFT JOIN provenance p ON p.id = cr.provenance_id
                      WHERE cr.subject_kind = 2 AND cr.subject_id = r.id ORDER BY cr.sort, cr.id LIMIT 1),
                     'local_tags')
                 FROM recording r WHERE r.work_id = ?1 AND NOT EXISTS (SELECT 1 FROM track t WHERE t.recording_id = r.id)
                 ORDER BY r.title COLLATE NOCASE, r.id"
            )?.query_map([work.0], |r| Ok(OtherRecording {
                recording: RecordingId(r.get(0)?), title: r.get(1)?, length_ms: r.get::<_, Option<i64>>(2)?.map(|n| n as u64), artists: vec![], source: r.get(3)?,
            }))?.collect::<rusqlite::Result<Vec<_>>>()?;
            let mut credits = c.prepare_cached(
                "SELECT a.id, a.name FROM credit cr JOIN agent a ON a.id = cr.agent_id
                 WHERE cr.subject_kind = 2 AND cr.subject_id = ?1 AND cr.role = 'artist' ORDER BY cr.sort, cr.id"
            )?;
            for recording in &mut others {
                recording.artists = credits.query_map([recording.recording.0], |r| Ok((AgentId(r.get(0)?), r.get(1)?)))?
                    .collect::<rusqlite::Result<_>>()?;
            }
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
            Ok(Some((title, composer, composers, parent, parts, tracks, others, recordings_known, plays, last_played)))
        })?;
        let Some((title, composer, composers, parent, parts, tracks, others, recordings_known, plays, last_played)) = found else { return Ok(None) };
        let tracks = self.track_rows(&tracks)?;
        Ok(Some(WorkPage { work, title, composer, composers, parent, parts, tracks, others, recordings_known, plays, last_played }))
    }

    /// None when the game doesn't exist.
    pub fn game_page(&self, game: GameId) -> Result<Option<GamePage>> {
        let found = self.read(|c| {
            let Some(mut page) = c.query_row(
                "SELECT title, year, developers, platforms, series FROM game WHERE id = ?1",
                [game.0],
                |r| Ok(GamePage {
                    game, title: r.get(0)?, year: r.get(1)?, developers: r.get(2)?, platforms: r.get(3)?, series: r.get(4)?,
                    soundtracks: vec![], composers: vec![], same_series: vec![], tracks: vec![], plays: 0, last_played: None,
                }),
            ).optional()? else { return Ok(None) };
            let sql = format!(
                "SELECT rl.id, rl.title, rl.year,
                     (SELECT COUNT(*) FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                      WHERE e.release_id = rl.id AND {PREFERRED_SOURCE} IS NOT NULL) AS n
                 FROM release rl WHERE n > 0 AND EXISTS (SELECT 1 FROM edge x
                     WHERE x.from_kind = 3 AND x.from_id = rl.id AND x.to_kind = 13 AND x.to_id = ?1 AND x.kind = 'soundtrack_of')
                 ORDER BY rl.year IS NULL, rl.year, rl.title COLLATE NOCASE, rl.id"
            );
            page.soundtracks = c.prepare(&sql)?.query_map([game.0], |r| {
                let tracks = r.get(3)?;
                Ok(PersonRelease { release: ReleaseId(r.get(0)?), title: r.get(1)?, year: r.get(2)?, theirs: tracks, tracks })
            })?.collect::<rusqlite::Result<_>>()?;
            page.composers = c.prepare(
                "SELECT a.id, a.name, cr.detail, COALESCE(p.source, 'local_tags')
                 FROM credit cr JOIN agent a ON a.id = cr.agent_id LEFT JOIN provenance p ON p.id = cr.provenance_id
                 WHERE cr.subject_kind = 13 AND cr.subject_id = ?1 AND cr.role = 'composer' ORDER BY cr.sort, cr.id"
            )?.query_map([game.0], |r| Ok(PersonLink {
                agent: AgentId(r.get(0)?), name: r.get(1)?, detail: r.get(2)?, source: r.get(3)?, tracks: 0,
            }))?.collect::<rusqlite::Result<_>>()?;
            for composer in &mut page.composers {
                composer.tracks = person_tracks(c, composer.agent)?;
            }
            let sql = format!(
                "SELECT g.id, g.title, g.year, 'wikidata' FROM game g
                 WHERE g.id <> ?1 AND g.series_ref = (SELECT series_ref FROM game WHERE id = ?1)
                 AND EXISTS (SELECT 1 FROM edge x JOIN edition e ON e.release_id = x.from_id
                     JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
                     WHERE x.from_kind = 3 AND x.to_kind = 13 AND x.to_id = g.id AND x.kind = 'soundtrack_of'
                     AND {PREFERRED_SOURCE} IS NOT NULL)
                 ORDER BY g.year IS NULL, g.year, g.title COLLATE NOCASE, g.id"
            );
            page.same_series = c.prepare(&sql)?.query_map([game.0], game_link)?.collect::<rusqlite::Result<_>>()?;
            let sql = format!(
                "SELECT t.id FROM track t JOIN medium m ON m.id = t.medium_id
                 JOIN edition e ON e.id = m.edition_id JOIN release rl ON rl.id = e.release_id
                 WHERE {PREFERRED_SOURCE} IS NOT NULL AND EXISTS (SELECT 1 FROM edge x
                     WHERE x.from_kind = 3 AND x.from_id = rl.id AND x.to_kind = 13 AND x.to_id = ?1 AND x.kind = 'soundtrack_of')
                 ORDER BY rl.year IS NULL, rl.year, rl.title COLLATE NOCASE, rl.id, m.position, t.position, t.id"
            );
            let tracks = c.prepare(&sql)?.query_map([game.0], |r| Ok(TrackId(r.get(0)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            (page.plays, page.last_played) = c.query_row(
                &format!(
                    "SELECT COUNT(*), MAX(l.started_at) FROM listen l {LISTEN_TRACK}
                     WHERE {COUNTED} AND EXISTS (SELECT 1 FROM edge x WHERE x.from_kind = 3 AND x.from_id = rl.id
                         AND x.to_kind = 13 AND x.to_id = ?1 AND x.kind = 'soundtrack_of')",
                    LISTEN_TRACK = crate::listens::LISTEN_TRACK, COUNTED = crate::listens::COUNTED
                ),
                [game.0], |r| Ok((r.get::<_, i64>(0)? as u64, r.get(1)?)),
            )?;
            Ok(Some((page, tracks)))
        })?;
        let Some((mut page, tracks)) = found else { return Ok(None) };
        page.tracks = self.track_rows(&tracks)?;
        Ok(Some(page))
    }

    /// A game's title, for naming a trail stop.
    pub fn game_title(&self, game: GameId) -> Result<Option<String>> {
        self.read(|c| c.query_row("SELECT title FROM game WHERE id = ?1", [game.0], |r| r.get(0)).optional())
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

fn game_link(row: &rusqlite::Row<'_>) -> rusqlite::Result<GameLink> {
    Ok(GameLink { game: GameId(row.get(0)?), title: row.get(1)?, year: row.get(2)?, source: row.get(3)? })
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

fn person_tracks(c: &Connection, agent: AgentId) -> rusqlite::Result<u64> {
    let sql = format!(
        "SELECT COUNT(*) FROM track t WHERE {PREFERRED_SOURCE} IS NOT NULL AND t.id IN (
             SELECT t.id FROM credit cr JOIN track t ON t.recording_id = cr.subject_id
             WHERE cr.subject_kind = 2 AND cr.agent_id = ?1
             UNION
             SELECT t.id FROM credit cr JOIN edition e ON e.release_id = cr.subject_id
             JOIN medium m ON m.edition_id = e.id JOIN track t ON t.medium_id = m.id
             WHERE cr.subject_kind = 3 AND cr.agent_id = ?1
             UNION
             SELECT t.id FROM credit cr JOIN work w ON w.id = cr.subject_id OR w.parent_id = cr.subject_id
             JOIN recording r ON r.work_id = w.id JOIN track t ON t.recording_id = r.id
             WHERE cr.subject_kind = 1 AND cr.agent_id = ?1)"
    );
    c.prepare_cached(&sql)?.query_row([agent.0], |r| Ok(r.get::<_, i64>(0)? as u64))
}

fn person_links(c: &Connection, agent: AgentId, kind: &str, outbound: bool) -> rusqlite::Result<Vec<PersonLink>> {
    let direction = if kind == "worked_with" {
        "(e.from_id = ?1 OR e.to_id = ?1)"
    } else if outbound {
        "e.from_id = ?1"
    } else {
        "e.to_id = ?1"
    };
    let sql = format!(
        "SELECT a.id, a.name, e.detail, COALESCE(p.source, 'local_tags')
         FROM edge e JOIN agent a ON a.id = CASE WHEN e.from_id = ?1 THEN e.to_id ELSE e.from_id END
         LEFT JOIN provenance p ON p.id = e.provenance_id
         WHERE e.from_kind = 6 AND e.to_kind = 6 AND e.kind = ?2 AND {direction}
         ORDER BY e.id"
    );
    let mut links = c.prepare_cached(&sql)?.query_map((agent.0, kind), |r| Ok(PersonLink {
        agent: AgentId(r.get(0)?), name: r.get(1)?, detail: r.get(2)?, source: r.get(3)?, tracks: 0,
    }))?.collect::<rusqlite::Result<Vec<_>>>()?;
    for link in &mut links {
        link.tracks = person_tracks(c, link.agent)?;
    }
    links.sort_by(|a, b| b.tracks.cmp(&a.tracks).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
    Ok(links)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn games_connect_soundtracks_composers_and_exact_name_queries() {
        let dir = std::env::temp_dir().join(format!("meret-game-pages-{}", ulid::Ulid::generate()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO provenance(id,source,fetched_at) VALUES(1,'wikidata',100),(2,'you',200);
                 INSERT INTO game(id,title,year,developers,platforms,series,series_ref,rev) VALUES
                    (1,'Skyglass',2000,'Lantern Studio','Glass Console','Skyglass tales','Q100',1),
                    (2,'Skyglass Echo',2002,NULL,NULL,'Skyglass tales','Q100',1),
                    (3,'Hidden Glass',2001,NULL,NULL,'Skyglass tales','Q100',1),
                    (4,'Elsewhere',2003,NULL,NULL,'Other tales','Q200',1),
                    (5,'Unlinked',NULL,NULL,NULL,NULL,NULL,1);
                 INSERT INTO agent(id,kind,name,rev) VALUES(1,0,'Elra Venn',1),(2,0,'Orva Renn',1);
                 INSERT INTO release(id,title,year,rev) VALUES
                    (1,'Later score',2001,1),(2,'Earlier score',1999,1),(3,'Echo score',2002,1),
                    (4,'Absent score',2003,1),(5,'Other score',2004,1);
                 INSERT INTO edition(id,release_id,rev) VALUES(1,1,1),(2,2,1),(3,3,1),(4,4,1),(5,5,1);
                 INSERT INTO medium(id,edition_id,position) VALUES(1,1,1),(2,1,2),(3,2,1),(4,3,1),(5,4,1),(6,5,1);
                 INSERT INTO recording(id,title,length_ms,rev) VALUES
                    (1,'Second',1000,1),(2,'Third',1000,1),(3,'First',1000,1),
                    (4,'Echo',1000,1),(5,'Absent',1000,1),(6,'Other',1000,1);
                 INSERT INTO track(id,medium_id,position,recording_id,rev) VALUES
                    (1,1,2,1,1),(2,2,1,2,1),(3,3,1,3,1),(4,4,1,4,1),(5,5,1,5,1),(6,6,1,6,1);
                 INSERT INTO root(id,label,path,kind) VALUES(1,'Music','/music','local');
                 INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES
                    (1,1,'one.flac',1,1,1),(2,1,'two.flac',1,1,1),(3,1,'three.flac',1,1,1),
                    (4,1,'four.flac',1,1,1),(6,1,'six.flac',1,1,1);
                 INSERT INTO source(id,recording_id,track_id,kind,file_id,rev) VALUES
                    (1,1,1,'file',1,1),(2,2,2,'file',2,1),(3,3,3,'file',3,1),(4,4,4,'file',4,1),(6,6,6,'file',6,1);
                 INSERT INTO edge(from_kind,from_id,to_kind,to_id,kind,provenance_id,rev) VALUES
                    (3,1,13,1,'soundtrack_of',1,1),(3,2,13,1,'soundtrack_of',2,1),
                    (3,3,13,2,'soundtrack_of',1,1),(3,4,13,1,'soundtrack_of',1,1),
                    (3,5,13,4,'soundtrack_of',1,1),(2,5,13,1,'soundtrack_of',1,1);
                 INSERT INTO credit(subject_kind,subject_id,agent_id,role,sort,provenance_id,rev) VALUES
                    (13,1,1,'composer',1,1,1),(13,1,2,'composer',0,1,1),(13,3,1,'composer',0,1,1),
                    (2,1,1,'performer',0,2,1),(2,1,1,'composer',0,1,1),(3,2,1,'album_artist',0,2,1);
                 INSERT INTO listen(uid,recording_id,source_id,started_at,played_ms,device) VALUES
                    ('one',1,1,100,600,'test'),('two',3,3,200,600,'test'),('short',2,2,300,100,'test'),
                    ('other',4,4,400,600,'test');"
            )?;
            Ok(())
        }).unwrap();

        let game = store.game_page(GameId(1)).unwrap().unwrap();
        assert_eq!((game.game, game.title.as_str(), game.year), (GameId(1), "Skyglass", Some(2000)));
        assert_eq!((game.developers.as_deref(), game.platforms.as_deref(), game.series.as_deref()),
            (Some("Lantern Studio"), Some("Glass Console"), Some("Skyglass tales")));
        assert_eq!(game.soundtracks.iter().map(|r| (r.release, r.tracks, r.theirs)).collect::<Vec<_>>(),
            [(ReleaseId(2), 1, 1), (ReleaseId(1), 2, 2)]);
        assert_eq!(game.tracks.iter().map(|t| t.track).collect::<Vec<_>>(), [TrackId(3), TrackId(1), TrackId(2)]);
        assert_eq!(game.composers.iter().map(|p| (p.agent, p.tracks, p.source.as_str())).collect::<Vec<_>>(),
            [(AgentId(2), 0, "wikidata"), (AgentId(1), 2, "wikidata")]);
        assert_eq!(game.same_series, [
            GameLink { game: GameId(2), title: "Skyglass Echo".into(), year: Some(2002), source: "wikidata".into() },
        ]);
        assert_eq!((game.plays, game.last_played), (2, Some(200)));
        assert_eq!(store.game_title(GameId(1)).unwrap().as_deref(), Some("Skyglass"));
        assert!(store.game_page(GameId(99)).unwrap().is_none());
        assert!(store.game_title(GameId(99)).unwrap().is_none());
        let unlinked = store.game_page(GameId(5)).unwrap().unwrap();
        assert!(unlinked.soundtracks.is_empty() && unlinked.tracks.is_empty() && unlinked.same_series.is_empty());
        assert_eq!((unlinked.plays, unlinked.last_played), (0, None));
        assert_eq!(store.release_page(ReleaseId(1)).unwrap().unwrap().games, [
            GameLink { game: GameId(1), title: "Skyglass".into(), year: Some(2000), source: "wikidata".into() },
        ]);
        assert_eq!(store.release_page(ReleaseId(2)).unwrap().unwrap().games[0].source, "you");
        assert_eq!(store.person_page(AgentId(1)).unwrap().unwrap().games.iter().map(|g| g.game).collect::<Vec<_>>(),
            [GameId(1), GameId(3)]);
        let mut exact = store.tracks_in_game_named("SKYGLASS").unwrap();
        exact.sort_unstable();
        assert_eq!(exact, [TrackId(1), TrackId(2), TrackId(3), TrackId(5)]);
        let mut contains = store.tracks_in_game_named("skygl").unwrap();
        contains.sort_unstable();
        assert_eq!(contains, [TrackId(1), TrackId(2), TrackId(3), TrackId(4), TrackId(5)]);
        assert!(store.tracks_in_game_named("Sky%").unwrap().is_empty());
        let cols = store.load_columns().unwrap();
        let meret_query::Input::Search(query) = meret_query::parse("game:skyglass").unwrap() else { panic!("query") };
        let rows = store.answer_residual(crate::plan(&query, &cols, 0), &cols).unwrap().unwrap();
        let mut planned = rows.iter().map(|i| cols.track[i as usize]).collect::<Vec<_>>();
        planned.sort_unstable();
        assert_eq!(planned, [TrackId(1), TrackId(2), TrackId(3)]);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn provider_credits_links_and_trackless_recordings_reach_pages() {
        let dir = std::env::temp_dir().join(format!("meret-provider-pages-{}", ulid::Ulid::generate()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| {
            tx.execute_batch(
                "INSERT INTO provenance(id,source,fetched_at) VALUES(1,'musicbrainz',100);
                 INSERT INTO agent(id,kind,name,rev) VALUES
                    (1,0,'Elra Venn',1),(2,1,'Zora Ensemble',1),(3,1,'Aster Circle',1),
                    (4,0,'Tal Vero',1),(5,0,'Bera Nol',1),(6,0,'Nemi Vale',1),(8,0,'Orva Renn',1);
                 INSERT INTO work(id,title,recording_count,rev) VALUES(1,'Nightglass',42,1),(2,'Dayglass',NULL,1);
                 INSERT INTO release(id,title,rev) VALUES(1,'Lantern Trails',1);
                 INSERT INTO edition(id,release_id,rev) VALUES(1,1,1);
                 INSERT INTO medium(id,edition_id,position) VALUES(1,1,1);
                 INSERT INTO recording(id,work_id,title,length_ms,rev) VALUES
                    (1,1,'Owned One',1000,1),(2,1,'Owned Two',2000,1),
                    (3,1,'Zephyr Take',3000,1),(4,1,'Alpha Take',NULL,1),
                    (5,1,'Offline Take',5000,1),(6,2,'Another Work',6000,1);
                 INSERT INTO track(id,medium_id,position,recording_id,rev) VALUES(1,1,1,1,1),(2,1,2,2,1),(5,1,3,5,1);
                 INSERT INTO root(id,label,path,kind) VALUES(1,'Music','/music','local');
                 INSERT INTO file(id,root_id,rel_path,size,mtime_ns,rev) VALUES(1,1,'one.flac',1,1,1),(2,1,'two.flac',1,1,1);
                 INSERT INTO source(id,recording_id,track_id,kind,file_id,rev) VALUES(1,1,1,'file',1,1),(2,2,2,'file',2,1);
                 INSERT INTO credit(subject_kind,subject_id,agent_id,role,detail,sort,provenance_id,rev) VALUES
                    (2,1,1,'performer','glass bells',0,1,1),(2,2,1,'performer','glass bells',0,1,1),
                    (2,1,4,'engineer',NULL,0,NULL,1),
                    (2,1,2,'artist',NULL,0,1,1),(2,2,2,'artist',NULL,0,1,1),
                    (2,3,6,'artist',NULL,1,1,1),(2,3,2,'artist',NULL,0,1,1);
                 INSERT INTO edge(from_kind,from_id,to_kind,to_id,kind,detail,provenance_id,rev) VALUES
                    (6,1,6,3,'member_of',NULL,1,1),(6,1,6,2,'member_of','bells, 2000–',1,1),
                    (6,5,6,1,'member_of',NULL,NULL,1),(6,4,6,1,'member_of','mixing',1,1),
                    (6,2,6,1,'worked_with','stage',1,1),(6,1,6,5,'worked_with',NULL,NULL,1),
                    (2,1,6,3,'member_of',NULL,1,1);"
            )?;
            Ok(())
        }).unwrap();

        let release = store.release_page(ReleaseId(1)).unwrap().unwrap();
        assert_eq!(release.roles.len(), 2);
        let performer = &release.roles[0];
        assert_eq!((performer.agent, performer.role.as_str(), performer.detail.as_deref(), performer.source.as_str()),
            (AgentId(1), "performer", Some("glass bells"), "musicbrainz"));
        assert_eq!(performer.positions, [(1,1), (1,2)]);
        assert_eq!(release.roles[1].source, "local_tags");

        let person = store.person_page(AgentId(1)).unwrap().unwrap();
        assert_eq!(person.tracks, 2);
        assert_eq!(person.member_of, [
            PersonLink { agent: AgentId(2), name: "Zora Ensemble".into(), detail: Some("bells, 2000–".into()),
                source: "musicbrainz".into(), tracks: 2 },
            PersonLink { agent: AgentId(3), name: "Aster Circle".into(), detail: None,
                source: "musicbrainz".into(), tracks: 0 },
        ]);
        assert_eq!(person.members.iter().map(|l| (l.agent, l.tracks)).collect::<Vec<_>>(), [(AgentId(4),1), (AgentId(5),0)]);
        assert_eq!(person.members[0].detail.as_deref(), Some("mixing"));
        assert_eq!(person.members[1].source, "local_tags");
        assert_eq!(person.linked.iter().map(|l| (l.agent, l.tracks)).collect::<Vec<_>>(), [(AgentId(2),2), (AgentId(5),0)]);
        assert_eq!(person.linked[0].source, "musicbrainz");
        assert_eq!(person.linked[0].detail.as_deref(), Some("stage"));
        assert_eq!(person.linked[1].source, "local_tags");
        let ghost = store.person_page(AgentId(8)).unwrap().unwrap();
        assert_eq!((ghost.name.as_str(), ghost.tracks), ("Orva Renn", 0));
        assert!(store.person_page(AgentId(99)).unwrap().is_none());

        let work = store.work_page(WorkId(1)).unwrap().unwrap();
        assert_eq!(work.recordings_known, Some(42));
        assert_eq!(work.tracks.len(), 2);
        assert_eq!(work.others, [
            OtherRecording { recording: RecordingId(4), title: "Alpha Take".into(), length_ms: None, artists: vec![],
                source: "local_tags".into() },
            OtherRecording { recording: RecordingId(3), title: "Zephyr Take".into(), length_ms: Some(3000),
                artists: vec![(AgentId(2), "Zora Ensemble".into()), (AgentId(6), "Nemi Vale".into())],
                source: "musicbrainz".into() },
        ]);
        assert_eq!(store.work_page(WorkId(2)).unwrap().unwrap().recordings_known, None);
        drop(store);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
