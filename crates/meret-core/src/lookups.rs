//! MusicBrainz lookups as jobs. The scan leaves MusicBrainz IDs from tags in
//! `external_id`; with your consent each one becomes a `job` row, and one
//! runner thread takes them a request at a time (the HTTP client paces them
//! and answers repeats from `cache.db`). What a lookup says is written as rows
//! with a `musicbrainz` provenance; tags always win where both speak.

use std::sync::Arc;
use std::time::Duration;

use crossbeam_channel::{Receiver, RecvTimeoutError};
use meret_jobs::JobKind;
use meret_model::credit::{clean_name, name_key};
use meret_model::{EntityKind, ThreadKind};
use meret_provider::{Catalog, Claim, Context, ExternalRef, Field, Lookup, MemoryKv, ProviderError, RefKind, ThreadClaim};
use meret_store::{JobCounts, Lookups, NewJob, QueuedJob, Store};
use rusqlite::{OptionalExtension, Transaction, params};
use serde_json::Value;

use crate::{Core, status};

pub(crate) const PROVIDER: &str = "musicbrainz";

/// The job kind every provider's lookups share; the key names the provider.
pub(crate) const QUEUE: &str = "lookups";

/// Cached responses are good for a month; MusicBrainz changes slowly.
pub(crate) const CACHE_TTL_MS: i64 = 30 * 24 * 3_600_000;

/// `cache.db` behind the provider's HTTP client.
pub(crate) struct StoredResponses(pub meret_store::HttpCache);

impl meret_provider::Cache for StoredResponses {
    fn get(&self, url: &str) -> Option<meret_provider::CachedResponse> {
        self.0.get(url).map(|(status, body, fetched_at)| meret_provider::CachedResponse { status, body, fetched_at })
    }
    fn put(&self, url: &str, response: &meret_provider::CachedResponse) {
        self.0.put(url, response.status, &response.body, response.fetched_at);
    }
}

/// What the status line needs between jobs.
#[derive(Debug, Default)]
pub(crate) struct State {
    /// Jobs finished since the queue was last empty.
    batch_done: u64,
    /// The last request couldn't reach MusicBrainz.
    offline: bool,
}

/// Wakes the runner: new jobs, or consent changed.
pub(crate) fn wake(core: &Core) {
    let _ = core.lookups_wake.send(());
}

pub(crate) fn spawn_runner(core: Arc<Core>) {
    let Some(wakes) = core.lookups_wakes.lock().take() else { return };
    if let Err(e) = core.store.requeue_running(QUEUE) {
        tracing::error!(error = %e, "could not requeue running lookups");
    }
    std::thread::Builder::new()
        .name("meret-lookups".into())
        .spawn(move || run(&core, &wakes))
        .expect("lookup thread");
}

fn run(core: &Core, wakes: &Receiver<()>) {
    loop {
        publish(core);
        if core.settings().lookups != Lookups::Allowed {
            if wakes.recv().is_err() { return }
            continue;
        }
        let now = Context::now_ms();
        match core.store.next_job(QUEUE, now) {
            Ok(Some(job)) => {
                one(core, job);
                core.lookup_state.lock().batch_done += 1;
            }
            Ok(None) => {
                core.lookup_state.lock().batch_done = 0;
                publish(core);
                let next = core.store.job_counts(QUEUE).ok().and_then(|c| c.next_run_after);
                let wait = next.map(|at| Duration::from_millis((at - now).max(0) as u64));
                let woke = match wait {
                    Some(wait) => wakes.recv_timeout(wait),
                    None => wakes.recv().map_err(|_| RecvTimeoutError::Disconnected),
                };
                if woke == Err(RecvTimeoutError::Disconnected) { return }
            }
            Err(e) => {
                tracing::error!(error = %e, "could not take a lookup job");
                std::thread::sleep(Duration::from_secs(5));
            }
        }
    }
}

/// Runs one job and records how it went.
fn one(core: &Core, job: QueuedJob) {
    let ctx = Context { http: core.http.clone(), kv: Arc::new(MemoryKv::default()), provider: PROVIDER };
    let result = match (crate::matching::release_of(&job.key), crate::games::release_of(&job.key), subject(&job.key)) {
        (Some(release), _, _) => crate::matching::run(core, &ctx, release),
        (None, Some(release), _) => crate::games::run(core, &ctx, release),
        (None, None, Some(subject)) => core.runtime.block_on(provider_musicbrainz::MusicBrainz.lookup(&ctx, &subject))
            .map(|lookup| apply(&core.store, &subject, lookup, Context::now_ms())),
        (None, None, None) => {
            let _ = core.store.fail_job(job.id, "not a lookup", None, Context::now_ms());
            return;
        }
    };
    let now = Context::now_ms();
    let outcome = match result {
        Ok(written) => {
            core.lookup_state.lock().offline = false;
            match written {
                Ok(next) => {
                    if let Err(e) = core.store.enqueue_jobs(next) {
                        tracing::error!(error = %e, "could not queue follow-up lookups");
                    }
                    core.store.finish_job(job.id, now)
                }
                Err(e) => core.store.fail_job(job.id, &e.to_string(), None, now),
            }
        }
        Err(ProviderError::NotFound) => core.store.fail_job(job.id, "not found", None, now),
        Err(ProviderError::RateLimited(ms)) => core.store.fail_job(job.id, "rate limited", Some(now + ms.max(5_000)), now),
        Err(e @ (ProviderError::Offline(_) | ProviderError::Http(_))) => {
            core.lookup_state.lock().offline = matches!(e, ProviderError::Offline(_));
            core.store.fail_job(job.id, &e.to_string(), retry_at(job.attempts, now), now)
        }
        Err(e) => core.store.fail_job(job.id, &e.to_string(), None, now),
    };
    if let Err(e) = outcome {
        tracing::error!(error = %e, "could not record a lookup");
    }
    core.status.send_modify(status::bump_lookups);
}

/// Half a minute, doubling, at most an hour; six tries in all.
fn retry_at(attempts: u32, now: i64) -> Option<i64> {
    (attempts < 5).then(|| now + (30_000i64 << attempts).min(3_600_000))
}

/// Shows consent, progress and trouble on MusicBrainz's status line item.
pub(crate) fn publish(core: &Core) {
    let lookups = core.settings().lookups;
    let counts = core.store.job_counts(QUEUE).unwrap_or_default();
    let state = core.lookup_state.lock();
    let pending = counts.queued + counts.running;
    let (detail, ok) = match lookups {
        Lookups::Unasked => ("asks first".to_string(), true),
        Lookups::Off => ("off".to_string(), true),
        Lookups::Allowed if state.offline => ("offline".to_string(), false),
        Lookups::Allowed if pending > 0 => ("looking up".to_string(), true),
        Lookups::Allowed if counts.done > 0 => (format!("{} looked up", status::thousands(counts.done)), true),
        Lookups::Allowed => ("not used yet".to_string(), true),
    };
    let running = (lookups == Lookups::Allowed && pending > 0).then(|| meret_jobs::JobGroupStatus {
        verb: VERB.into(),
        done: state.batch_done,
        total: state.batch_done + pending,
        paused_because: state.offline.then(|| "offline".into()),
    });
    drop(state);
    core.status.send_modify(|s| status::set_source(s, PROVIDER, detail, ok, VERB, running));
}

const VERB: &str = "looking up";

/// The job key for looking up `value` as `kind`.
fn key(kind: RefKind, value: &str) -> String {
    JobKind::Fetch { provider: PROVIDER.into(), what: format!("{}:{value}", kind_name(kind)) }.dedupe_key()
}

fn subject(key: &str) -> Option<ExternalRef> {
    let what = key.strip_prefix(&format!("fetch:{PROVIDER}:"))?;
    let (kind, value) = what.split_once(':')?;
    let kind = match kind {
        "release" => RefKind::Release,
        "recording" => RefKind::Recording,
        "artist" => RefKind::Agent,
        "work" => RefKind::Work,
        _ => return None,
    };
    Some(ExternalRef::mbid(kind, value))
}

fn kind_name(kind: RefKind) -> &'static str {
    match kind {
        RefKind::Release => "release",
        RefKind::Recording => "recording",
        RefKind::Agent => "artist",
        RefKind::Work => "work",
        RefKind::Edition => "edition",
        RefKind::Label => "label",
    }
}

fn job(kind: RefKind, value: &str, priority: i32) -> NewJob {
    NewJob { key: key(kind, value), kind: QUEUE.into(), payload: None, priority }
}

/// Releases first: one release lookup names the IDs of its tracks and people.
const RELEASE: i32 = 30;
const RECORDING: i32 = 20;
const ARTIST: i32 = 10;
const WORK: i32 = 5;
/// Matching by name comes after every ID the tags carry.
const MATCH: i32 = 3;
/// Placing scores in their games comes last.
const GAME: i32 = 2;
/// A pane you opened goes ahead of everything.
const OPENED: i32 = 50;

/// Queues a lookup for every MusicBrainz ID your library's tags carry:
/// releases, recordings with a track, people credited on a track by the tags,
/// and works a track is a recording of; and a match by name for every release
/// without an ID. Anything else MusicBrainz names is looked up only when you
/// open it, so the lookups never crawl outwards.
pub(crate) fn seed(core: &Core) {
    let found = core.store.read(|c| {
        let mut stmt = c.prepare(
            "SELECT x.entity_kind, x.value FROM external_id x WHERE x.namespace = 'mbid' AND (
                x.entity_kind = 3
                OR (x.entity_kind = 2 AND EXISTS (SELECT 1 FROM track t WHERE t.recording_id = x.entity_id))
                OR (x.entity_kind = 6 AND EXISTS (SELECT 1 FROM credit cr JOIN provenance p ON p.id = cr.provenance_id
                    WHERE cr.agent_id = x.entity_id AND p.source = 'local_tags'))
                OR (x.entity_kind = 1 AND EXISTS (SELECT 1 FROM recording r JOIN track t ON t.recording_id = r.id
                    WHERE r.work_id = x.entity_id)))",
        )?;
        stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()
    });
    let mut jobs: Vec<NewJob> = match found {
        Ok(rows) => rows.iter().filter_map(|(kind, value)| match *kind {
            3 => Some(job(RefKind::Release, value, RELEASE)),
            2 => Some(job(RefKind::Recording, value, RECORDING)),
            6 => Some(job(RefKind::Agent, value, ARTIST)),
            1 => Some(job(RefKind::Work, value, WORK)),
            _ => None,
        }).collect(),
        Err(e) => return tracing::error!(error = %e, "could not list MusicBrainz IDs"),
    };
    match crate::matching::unidentified(&core.store) {
        Ok(releases) => jobs.extend(releases.into_iter().map(|id| NewJob {
            key: crate::matching::key(id), kind: QUEUE.into(), payload: None, priority: MATCH,
        })),
        Err(e) => return tracing::error!(error = %e, "could not list releases to match"),
    }
    match crate::games::unplaced(&core.store) {
        Ok(releases) => jobs.extend(releases.into_iter().map(|id| NewJob {
            key: crate::games::key(id), kind: QUEUE.into(), payload: None, priority: GAME,
        })),
        Err(e) => return tracing::error!(error = %e, "could not list scores to place"),
    }
    match core.store.enqueue_jobs(jobs) {
        Ok(0) => {}
        Ok(_) => wake(core),
        Err(e) => tracing::error!(error = %e, "could not queue lookups"),
    }
}

/// Puts an opened person, release or work with a MusicBrainz ID first in line.
pub(crate) fn opened(core: &Core, kind: EntityKind, id: i64) {
    if core.settings().lookups != Lookups::Allowed { return }
    let mbid = core.store.read(|c| c.query_row(
        "SELECT value FROM external_id WHERE entity_kind = ?1 AND entity_id = ?2 AND namespace = 'mbid'",
        params![kind as i64, id], |r| r.get::<_, String>(0)).optional());
    let Ok(Some(mbid)) = mbid else { return };
    let kind = match kind {
        EntityKind::Agent => RefKind::Agent,
        EntityKind::Release => RefKind::Release,
        EntityKind::Work => RefKind::Work,
        EntityKind::Recording => RefKind::Recording,
        _ => return,
    };
    if core.store.enqueue_jobs(vec![job(kind, &mbid, OPENED)]).is_ok() { wake(core) }
}

/// The MusicBrainz IDs your tags carry, by kind, the releases to match by
/// name, and what the lookups have done.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LookupSummary {
    pub releases: u64,
    pub recordings: u64,
    pub people: u64,
    /// Releases without an ID, from tags or a match.
    pub unidentified: u64,
    /// Releases a match by name identified.
    pub matched: u64,
    pub jobs: JobCounts,
}

pub(crate) fn summary(core: &Core) -> meret_store::Result<LookupSummary> {
    let (releases, recordings, people, matched) = core.store.read(|c| c.query_row(
        "SELECT
            (SELECT COUNT(*) FROM external_id WHERE namespace = 'mbid' AND entity_kind = 3 AND provenance_id IS NULL),
            (SELECT COUNT(*) FROM external_id x WHERE namespace = 'mbid' AND entity_kind = 2 AND provenance_id IS NULL
                AND EXISTS (SELECT 1 FROM track t WHERE t.recording_id = x.entity_id)),
            (SELECT COUNT(*) FROM external_id x WHERE namespace = 'mbid' AND entity_kind = 6 AND provenance_id IS NULL
                AND EXISTS (SELECT 1 FROM credit cr JOIN provenance p ON p.id = cr.provenance_id
                    WHERE cr.agent_id = x.entity_id AND p.source = 'local_tags')),
            (SELECT COUNT(*) FROM external_id WHERE namespace = 'mbid' AND entity_kind = 3 AND provenance_id IS NOT NULL)",
        [], |r| Ok((r.get::<_, i64>(0)? as u64, r.get::<_, i64>(1)? as u64, r.get::<_, i64>(2)? as u64, r.get::<_, i64>(3)? as u64)),
    ))?;
    let unidentified = crate::matching::unidentified(&core.store)?.len() as u64;
    Ok(LookupSummary { releases, recordings, people, unidentified, matched, jobs: core.store.job_counts(QUEUE)? })
}

/// Records a match by name: the release gets the match's ID, with the
/// catalogue's score as its confidence, and is looked up next.
pub(crate) fn matched(store: &Store, release: i64, hit: &meret_provider::CatalogHit, now: i64) -> meret_store::Result<Vec<NewJob>> {
    let (mbid, score) = (hit.subject.value.clone(), hit.score as f64);
    store.writer.write(move |tx| {
        let rev = meret_store::next_rev(tx)?;
        let provenance: i64 = tx.query_row(
            "INSERT INTO provenance (source, external_ref, fetched_at, confidence) VALUES (?1, ?2, ?3, ?4) RETURNING id",
            params![PROVIDER, mbid, now, score], |r| r.get(0),
        )?;
        let w = Writer { tx, rev, provenance, next: vec![] };
        Ok(if w.identify(EntityKind::Release, release, "mbid", &mbid)? { vec![job(RefKind::Release, &mbid, RELEASE)] } else { vec![] })
    })
}

/// Writes what one lookup said, in one transaction, and returns the lookups it leads to.
pub(crate) fn apply(store: &Store, subject: &ExternalRef, lookup: Lookup, now: i64) -> meret_store::Result<Vec<NewJob>> {
    let subject = subject.clone();
    store.writer.write(move |tx| {
        let rev = meret_store::next_rev(tx)?;
        let provenance: i64 = tx.query_row(
            "INSERT INTO provenance (source, external_ref, fetched_at, confidence) VALUES (?1, ?2, ?3, 1.0) RETURNING id",
            params![PROVIDER, subject.value, now], |r| r.get(0),
        )?;
        let mut w = Writer { tx, rev, provenance, next: vec![] };
        match subject.kind {
            RefKind::Release => w.release(&subject, &lookup)?,
            RefKind::Recording => w.recording(&subject, &lookup)?,
            RefKind::Agent => w.artist(&subject, &lookup)?,
            RefKind::Work => w.work(&subject, &lookup)?,
            RefKind::Edition | RefKind::Label => {}
        }
        Ok(w.next)
    })
}

struct Writer<'a, 't> {
    tx: &'a Transaction<'t>,
    rev: i64,
    provenance: i64,
    next: Vec<NewJob>,
}

/// One credit claim: who, as what, with what detail.
struct Credited<'c> {
    agent: ExternalRef,
    name: &'c str,
    detail: Option<&'c str>,
}

fn credited(claim: &Claim) -> Option<Credited<'_>> {
    let agent: ExternalRef = serde_json::from_value(claim.value.get("agent")?.clone()).ok()?;
    Some(Credited { agent, name: claim.value.get("name")?.as_str()?, detail: claim.value.get("detail").and_then(Value::as_str) })
}

fn about<'l>(lookup: &'l Lookup, subject: &'l ExternalRef) -> impl Iterator<Item = &'l Claim> + 'l {
    lookup.claims.iter().filter(move |c| c.subject == *subject)
}

fn role_of(field: &Field) -> Option<&str> {
    match field { Field::Credit { role } => Some(role), _ => None }
}

impl Writer<'_, '_> {
    /// The entity an MBID already belongs to.
    fn local(&self, kind: EntityKind, mbid: &str) -> rusqlite::Result<Option<i64>> {
        self.tx.query_row(
            "SELECT entity_id FROM external_id WHERE namespace = 'mbid' AND value = ?1 AND entity_kind = ?2",
            params![mbid, kind as i64], |r| r.get(0),
        ).optional()
    }

    /// Gives `id` this MBID unless it already has one, or the MBID is someone else's.
    fn identify(&self, kind: EntityKind, id: i64, namespace: &str, value: &str) -> rusqlite::Result<bool> {
        let has: bool = self.tx.query_row(
            "SELECT EXISTS (SELECT 1 FROM external_id WHERE entity_kind = ?1 AND entity_id = ?2 AND namespace = ?3)",
            params![kind as i64, id, namespace], |r| r.get(0),
        )?;
        if has { return Ok(false) }
        Ok(self.tx.execute(
            "INSERT OR IGNORE INTO external_id (entity_kind, entity_id, namespace, value, provenance_id) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![kind as i64, id, namespace, value, self.provenance],
        )? == 1)
    }

    /// The person or group an MBID names: the one with that ID, else one of
    /// that name without an ID (credited on `near` when given), else a new one.
    /// New people stay out of search: they're reachable by threads only.
    fn agent(&self, who: &ExternalRef, name: &str, near: Option<(EntityKind, i64)>) -> rusqlite::Result<i64> {
        if let Some(id) = self.local(EntityKind::Agent, &who.value)? { return Ok(id) }
        let key = name_key(name);
        let unnamed = "NOT EXISTS (SELECT 1 FROM external_id x WHERE x.entity_kind = 6 AND x.entity_id = a.id AND x.namespace = 'mbid')";
        let same: Option<i64> = match near {
            Some((kind, id)) => self.tx.query_row(
                &format!("SELECT a.id FROM agent a JOIN credit cr ON cr.agent_id = a.id
                    WHERE cr.subject_kind = ?1 AND cr.subject_id = ?2 AND a.normalized_name = ?3 AND {unnamed} LIMIT 1"),
                params![kind as i64, id, key], |r| r.get(0)).optional()?,
            None => None,
        };
        let same = match same {
            Some(id) => Some(id),
            None => self.tx.query_row(
                &format!("SELECT a.id FROM agent a WHERE a.normalized_name = ?1 AND {unnamed} ORDER BY a.id LIMIT 1"),
                [&key], |r| r.get(0)).optional()?,
        };
        let id = match same {
            Some(id) => id,
            None => self.tx.query_row(
                "INSERT INTO agent (kind, name, normalized_name, rev) VALUES (0, ?1, ?2, ?3) RETURNING id",
                params![clean_name(name), key, self.rev], |r| r.get(0),
            )?,
        };
        self.identify(EntityKind::Agent, id, "mbid", &who.value)?;
        Ok(id)
    }

    /// A credit unless the subject already credits that person in that role, from any source.
    fn credit(&self, kind: EntityKind, subject: i64, agent: i64, role: &str, detail: Option<&str>, sort: usize) -> rusqlite::Result<()> {
        self.tx.execute(
            "INSERT INTO credit (subject_kind, subject_id, agent_id, role, detail, sort, provenance_id, rev)
             SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8 WHERE NOT EXISTS (
                SELECT 1 FROM credit WHERE subject_kind = ?1 AND subject_id = ?2 AND agent_id = ?3 AND role = ?4)",
            params![kind as i64, subject, agent, role, detail, sort as i64, self.provenance, self.rev],
        )?;
        Ok(())
    }

    /// The people the tags credit on `subject` in `role`, in order.
    fn tagged(&self, kind: EntityKind, subject: i64, role: &str) -> rusqlite::Result<Vec<i64>> {
        self.tx.prepare(
            "SELECT cr.agent_id FROM credit cr JOIN provenance p ON p.id = cr.provenance_id
             WHERE cr.subject_kind = ?1 AND cr.subject_id = ?2 AND cr.role = ?3 AND p.source = 'local_tags' ORDER BY cr.sort, cr.id",
        )?.query_map(params![kind as i64, subject, role], |r| r.get(0))?.collect()
    }

    /// Gives the tagged people MusicBrainz's IDs when both list the same number,
    /// in order, as the scan does with artist ID tags; then looks them up.
    fn identify_people(&mut self, kind: EntityKind, subject: i64, role: &str, credits: &[Credited<'_>]) -> rusqlite::Result<()> {
        let tagged = self.tagged(kind, subject, role)?;
        if tagged.len() != credits.len() { return Ok(()) }
        for (agent, c) in tagged.iter().zip(credits) {
            self.identify(EntityKind::Agent, *agent, "mbid", &c.agent.value)?;
            if self.local(EntityKind::Agent, &c.agent.value)? == Some(*agent) {
                self.next.push(job(RefKind::Agent, &c.agent.value, ARTIST));
            }
        }
        Ok(())
    }

    fn release(&mut self, subject: &ExternalRef, lookup: &Lookup) -> rusqlite::Result<()> {
        let Some(release) = self.local(EntityKind::Release, &subject.value)? else { return Ok(()) };
        let mut label = None;
        let mut catalog = None;
        let mut artists = vec![];
        for c in about(lookup, subject) {
            match &c.field {
                Field::Label => { label = label.or(c.value.as_str()) }
                Field::CatalogNumber => { catalog = catalog.or(c.value.as_str()) }
                Field::SameAs => if let Ok(r) = serde_json::from_value::<ExternalRef>(c.value.clone()) {
                    self.identify(EntityKind::Release, release, &r.namespace, &r.value)?;
                },
                Field::Credit { role } if role == "album_artist" => artists.extend(credited(c)),
                _ => {}
            }
        }
        self.tx.execute(
            "UPDATE edition SET label = COALESCE(label, ?2), catalog_no = COALESCE(catalog_no, ?3), rev = ?4
             WHERE release_id = ?1 AND is_default = 1 AND (label IS NULL OR catalog_no IS NULL)",
            params![release, label, catalog, self.rev],
        )?;
        self.identify_people(EntityKind::Release, release, "album_artist", &artists)?;

        // Each track's recording, by disc and position on this release. A
        // release matched by name may be laid out differently from yours, so
        // its tracks pair by title instead, where a title names one track on
        // each side.
        let matched: bool = self.tx.query_row(
            "SELECT provenance_id IS NOT NULL FROM external_id WHERE entity_kind = 3 AND entity_id = ?1 AND namespace = 'mbid' AND value = ?2",
            params![release, subject.value], |r| r.get(0),
        )?;
        let positions: Vec<&Claim> = lookup.claims.iter().filter(|c| c.field == Field::Position && c.subject.kind == RefKind::Recording).collect();
        let by_title = if matched { self.tracks_by_title(release, &positions)? } else { Default::default() };
        for c in positions {
            let recording = if matched {
                c.value["title"].as_str().and_then(|t| by_title.get(&crate::matching::fold(t)).copied())
            } else {
                let (Some(disc), Some(position)) = (c.value["disc"].as_i64(), c.value["track"].as_i64()) else { continue };
                self.tx.query_row(
                    "SELECT t.recording_id FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                     WHERE e.release_id = ?1 AND e.is_default = 1 AND m.position = ?2 AND t.position = ?3",
                    params![release, disc, position], |r| r.get(0),
                ).optional()?
            };
            let Some(recording) = recording else { continue };
            self.identify(EntityKind::Recording, recording, "mbid", &c.subject.value)?;
            if self.local(EntityKind::Recording, &c.subject.value)? != Some(recording) { continue }
            self.next.push(job(RefKind::Recording, &c.subject.value, RECORDING));
            let artists: Vec<Credited<'_>> = about(lookup, &c.subject)
                .filter(|c| role_of(&c.field) == Some("artist")).filter_map(credited).collect();
            self.identify_people(EntityKind::Recording, recording, "artist", &artists)?;
        }
        Ok(())
    }

    /// Your tracks on `release` by folded title, for the titles that name one
    /// track here and one in `positions`. A note your tags add after a dash
    /// ("Alexander Peace (Greece) – Epitaph of Seikilos") may be set aside.
    fn tracks_by_title(&self, release: i64, positions: &[&Claim]) -> rusqlite::Result<std::collections::HashMap<String, i64>> {
        use crate::matching::fold;
        let mut theirs: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
        for c in positions {
            if let Some(title) = c.value["title"].as_str() { *theirs.entry(fold(title)).or_default() += 1 }
        }
        let mut mine: std::collections::HashMap<String, Option<i64>> = std::collections::HashMap::new();
        let mut stmt = self.tx.prepare(
            "SELECT t.recording_id, COALESCE(t.title, r.title) FROM track t JOIN recording r ON r.id = t.recording_id
             JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id WHERE e.release_id = ?1 AND e.is_default = 1",
        )?;
        for row in stmt.query_map([release], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
            let (recording, title) = row?;
            let noted = [" – ", " — ", " - "].iter().find_map(|dash| title.split_once(dash)).map(|(head, _)| fold(head));
            let full = fold(&title);
            for key in std::iter::once(full.clone()).chain(noted.filter(|n| *n != full)) {
                mine.entry(key).and_modify(|r| *r = None).or_insert(Some(recording));
            }
        }
        Ok(mine.into_iter().filter_map(|(title, r)| (theirs.get(&title) == Some(&1)).then_some((title, r?))).collect())
    }

    fn recording(&mut self, subject: &ExternalRef, lookup: &Lookup) -> rusqlite::Result<()> {
        let Some(recording) = self.local(EntityKind::Recording, &subject.value)? else { return Ok(()) };
        let mut artists = vec![];
        let mut sort = 0;
        for c in about(lookup, subject) {
            match &c.field {
                Field::Isrc => if let Some(isrc) = c.value.as_str() {
                    self.tx.execute(
                        "INSERT OR IGNORE INTO external_id (entity_kind, entity_id, namespace, value) VALUES (2, ?1, 'isrc', ?2)",
                        params![recording, isrc],
                    )?;
                },
                Field::Credit { role } if role == "artist" => artists.extend(credited(c)),
                Field::Credit { role } => if let Some(p) = credited(c) {
                    let agent = self.agent(&p.agent, p.name, Some((EntityKind::Recording, recording)))?;
                    self.credit(EntityKind::Recording, recording, agent, role, p.detail, sort)?;
                    sort += 1;
                    self.next.push(job(RefKind::Agent, &p.agent.value, ARTIST));
                },
                _ => {}
            }
        }
        self.identify_people(EntityKind::Recording, recording, "artist", &artists)?;
        for t in lookup.threads.iter().filter(|t| t.kind == ThreadKind::RecordingOf && t.from == *subject) {
            let work = self.work_for(recording, t)?;
            self.tx.execute("UPDATE recording SET work_id = ?2, rev = ?3 WHERE id = ?1 AND work_id IS NULL", params![recording, work, self.rev])?;
            self.next.push(job(RefKind::Work, &t.to.value, WORK));
        }
        Ok(())
    }

    /// The work a recording is of: the one with that ID, the recording's own
    /// tagged work when the titles agree, or a new one.
    fn work_for(&self, recording: i64, t: &ThreadClaim) -> rusqlite::Result<i64> {
        if let Some(id) = self.local(EntityKind::Work, &t.to.value)? { return Ok(id) }
        let tagged: Option<i64> = self.tx.query_row(
            "SELECT w.id FROM recording r JOIN work w ON w.id = r.work_id WHERE r.id = ?1 AND lower(w.title) = lower(?2)",
            params![recording, t.to_name], |r| r.get(0),
        ).optional()?;
        let id = match tagged {
            Some(id) => id,
            None => self.tx.query_row(
                "INSERT INTO work (title, rev) VALUES (?1, ?2) RETURNING id", params![t.to_name, self.rev], |r| r.get(0),
            )?,
        };
        self.identify(EntityKind::Work, id, "mbid", &t.to.value)?;
        Ok(id)
    }

    fn artist(&mut self, subject: &ExternalRef, lookup: &Lookup) -> rusqlite::Result<()> {
        let Some(agent) = self.local(EntityKind::Agent, &subject.value)? else { return Ok(()) };
        for c in about(lookup, subject) {
            match &c.field {
                Field::AgentType => {
                    let kind = if c.value.as_str() == Some("group") { 1 } else { 0 };
                    self.tx.execute("UPDATE agent SET kind = ?2 WHERE id = ?1", params![agent, kind])?;
                }
                Field::SortName => {
                    self.tx.execute("UPDATE agent SET sort_name = COALESCE(sort_name, ?2) WHERE id = ?1", params![agent, c.value.as_str()])?;
                }
                _ => {}
            }
        }
        for t in lookup.threads.iter().filter(|t| t.from == *subject) {
            let other = self.agent(&t.to, &t.to_name, None)?;
            let (from, to, kind) = match t.kind {
                ThreadKind::MemberOf => (agent, other, "member_of"),
                ThreadKind::HasMember => (other, agent, "member_of"),
                ThreadKind::WorkedWith => (agent, other, "worked_with"),
                _ => continue,
            };
            self.tx.execute(
                "INSERT OR IGNORE INTO edge (from_kind, from_id, to_kind, to_id, kind, detail, provenance_id, rev)
                 VALUES (6, ?1, 6, ?2, ?3, ?4, ?5, ?6)",
                params![from, to, kind, t.detail, self.provenance, self.rev],
            )?;
        }
        Ok(())
    }

    fn work(&mut self, subject: &ExternalRef, lookup: &Lookup) -> rusqlite::Result<()> {
        let Some(work) = self.local(EntityKind::Work, &subject.value)? else { return Ok(()) };
        let mut sort = 0;
        for c in about(lookup, subject) {
            match &c.field {
                Field::RecordingCount => {
                    self.tx.execute("UPDATE work SET recording_count = ?2 WHERE id = ?1", params![work, c.value.as_i64()])?;
                }
                Field::Credit { role } => if let Some(p) = credited(c) {
                    let agent = self.agent(&p.agent, p.name, Some((EntityKind::Work, work)))?;
                    self.credit(EntityKind::Work, work, agent, role, p.detail, sort)?;
                    sort += 1;
                },
                _ => {}
            }
        }
        // Every recording MusicBrainz knows of it: yours gain the work, the rest are kept to show.
        for t in lookup.threads.iter().filter(|t| t.kind == ThreadKind::RecordingOf && t.to == *subject) {
            match self.local(EntityKind::Recording, &t.from.value)? {
                Some(recording) => {
                    self.tx.execute("UPDATE recording SET work_id = ?2, rev = ?3 WHERE id = ?1 AND work_id IS NULL", params![recording, work, self.rev])?;
                }
                None => self.other_recording(work, &t.from, lookup)?,
            }
        }
        Ok(())
    }

    /// A recording you don't have, with its title, length and artists.
    fn other_recording(&self, work: i64, subject: &ExternalRef, lookup: &Lookup) -> rusqlite::Result<()> {
        let mut title = None;
        let mut length = None;
        let mut artists = vec![];
        for c in about(lookup, subject) {
            match &c.field {
                Field::Title => title = c.value.as_str(),
                Field::LengthMs => length = c.value.as_i64(),
                Field::Credit { role } if role == "artist" => artists.extend(credited(c)),
                _ => {}
            }
        }
        let Some(title) = title else { return Ok(()) };
        let written = artists.iter().map(|a| a.name).collect::<Vec<_>>().join(", ");
        let recording: i64 = self.tx.query_row(
            "INSERT INTO recording (work_id, title, length_ms, artist_credit, rev) VALUES (?1, ?2, ?3, ?4, ?5) RETURNING id",
            params![work, title, length, (!written.is_empty()).then_some(written), self.rev], |r| r.get(0),
        )?;
        self.identify(EntityKind::Recording, recording, "mbid", &subject.value)?;
        for (sort, a) in artists.iter().enumerate() {
            let agent = self.agent(&a.agent, a.name, None)?;
            self.credit(EntityKind::Recording, recording, agent, "artist", None, sort)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use meret_model::{AgentId, Provenance, ReleaseId, WorkId};
    use serde_json::json;

    fn claim(subject: &ExternalRef, field: Field, value: Value) -> Claim {
        Claim { subject: subject.clone(), field, value, provenance: Provenance { source: PROVIDER.into(), external_ref: None, fetched_at: 0, confidence: 1.0 } }
    }

    fn thread(from: &ExternalRef, to: &ExternalRef, name: &str, kind: ThreadKind, detail: Option<&str>) -> ThreadClaim {
        ThreadClaim { from: from.clone(), to: to.clone(), to_name: name.into(), kind, detail: detail.map(Into::into),
            provenance: Provenance { source: PROVIDER.into(), external_ref: None, fetched_at: 0, confidence: 1.0 } }
    }

    fn credit(role: &str, who: &ExternalRef, name: &str, detail: Option<&str>) -> (Field, Value) {
        (Field::Credit { role: role.into() }, json!({ "agent": who, "name": name, "detail": detail }))
    }

    fn keys(jobs: &[NewJob]) -> Vec<&str> {
        let mut keys: Vec<&str> = jobs.iter().map(|j| j.key.as_str()).collect();
        keys.sort();
        keys.dedup();
        keys
    }

    /// A two-track release the tags credit to one person.
    fn fixture() -> (std::path::PathBuf, Store) {
        let dir = std::env::temp_dir().join(format!("meret-lookups-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&dir).unwrap();
        let store = Store::open(&dir.join("library.db")).unwrap();
        store.writer.write(|tx| tx.execute_batch(
            "INSERT INTO provenance (id, source, fetched_at) VALUES (1, 'local_tags', 0);
             INSERT INTO release (id, title, rev) VALUES (1, 'Fixture Release', 1);
             INSERT INTO edition (id, release_id, is_default, rev) VALUES (1, 1, 1, 1);
             INSERT INTO medium (id, edition_id, position) VALUES (1, 1, 1);
             INSERT INTO recording (id, title, rev) VALUES (1, 'First Cue', 1), (2, 'Second Cue', 1);
             INSERT INTO track (id, medium_id, position, recording_id, title, rev) VALUES (1, 1, 1, 1, 'First Cue', 1), (2, 1, 2, 2, 'Second Cue', 1);
             INSERT INTO root (id, label, path, kind) VALUES (1, 'music', '/fixture', 'local');
             INSERT INTO file (id, root_id, rel_path, size, mtime_ns, rev) VALUES (1, 1, '1.flac', 1, 1, 1), (2, 1, '2.flac', 1, 1, 1);
             INSERT INTO source (id, recording_id, track_id, kind, file_id, rev) VALUES (1, 1, 1, 'file', 1, 1), (2, 2, 2, 'file', 2, 1);
             INSERT INTO agent (id, kind, name, normalized_name, rev) VALUES (1, 0, 'Ada Brennan', 'ada brennan', 1);
             INSERT INTO credit (subject_kind, subject_id, agent_id, role, provenance_id, rev) VALUES
                (2, 1, 1, 'artist', 1, 1), (2, 2, 1, 'artist', 1, 1), (3, 1, 1, 'album_artist', 1, 1);")).unwrap();
        (dir, store)
    }

    #[test]
    fn a_release_matched_by_name_gives_its_tracks_ids_only_where_titles_agree() {
        let (dir, store) = fixture();
        let local = crate::matching::local(&store, 1).unwrap().unwrap();
        assert_eq!((local.title.as_str(), local.artists.as_slice(), local.tracks, local.discs), ("Fixture Release", &["Ada Brennan".to_string()][..], 2, 1));
        let hit = meret_provider::CatalogHit {
            subject: ExternalRef::mbid(RefKind::Release, "rel"), title: "Fixture Release".into(), artist: "Ada Brennan".into(),
            length_ms: None, score: 1.0, tracks: Some(2), discs: Some(1), artists: vec!["Ada Brennan".into()], group: Some("g".into()),
        };
        assert_eq!(keys(&matched(&store, 1, &hit, 1).unwrap()), ["fetch:musicbrainz:release:rel"]);
        let rel = ExternalRef::mbid(RefKind::Release, "rel");
        // Laid out differently from yours, with a note your tags add, and a track you don't have.
        store.writer.write(|tx| tx.execute("UPDATE track SET title = 'Second Cue – a fixture note' WHERE id = 2", [])).unwrap();
        let mut release = Lookup::default();
        for (r, n, title) in [("r0", 1, "Opening"), ("r1", 2, "First Cue"), ("r2", 3, "Second Cue")] {
            release.claims.push(claim(&ExternalRef::mbid(RefKind::Recording, r), Field::Position, json!({ "release": "rel", "disc": 1, "track": n, "title": title })));
        }
        assert_eq!(keys(&apply(&store, &rel, release, 2).unwrap()), ["fetch:musicbrainz:recording:r1", "fetch:musicbrainz:recording:r2"]);
        let ids = store.read(|c| c.prepare("SELECT entity_kind, entity_id, value, p.confidence FROM external_id x JOIN provenance p ON p.id = x.provenance_id ORDER BY 1, 2")?
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?, r.get::<_, f64>(3)?)))?.collect::<rusqlite::Result<Vec<_>>>()).unwrap();
        assert_eq!(ids, [(2, 1, "r1".to_string(), 1.0), (2, 2, "r2".to_string(), 1.0), (3, 1, "rel".to_string(), 1.0)]);
        assert_eq!(crate::matching::unidentified(&store).unwrap(), Vec::<i64>::new());
        drop(store);
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn lookups_identify_tagged_rows_and_add_sourced_facts_once() {
        let (dir, store) = fixture();
        store.writer.write(|tx| tx.execute("INSERT INTO external_id (entity_kind, entity_id, namespace, value) VALUES (3, 1, 'mbid', 'rel')", [])).unwrap();

        let rel = ExternalRef::mbid(RefKind::Release, "rel");
        let (r1, r2) = (ExternalRef::mbid(RefKind::Recording, "r1"), ExternalRef::mbid(RefKind::Recording, "r2"));
        let ada = ExternalRef::mbid(RefKind::Agent, "ada");
        let mut release = Lookup::default();
        release.claims.push(claim(&rel, Field::Label, json!("Fixture Label")));
        let (field, value) = credit("album_artist", &ada, "Ada B.", None);
        release.claims.push(claim(&rel, field, value));
        for (r, n) in [(&r1, 1), (&r2, 2)] {
            release.claims.push(claim(r, Field::Position, json!({ "release": "rel", "disc": 1, "track": n, "title": "x" })));
            let (field, value) = credit("artist", &ada, "Ada B.", None);
            release.claims.push(claim(r, field, value));
        }
        let next = apply(&store, &rel, release.clone(), 1).unwrap();
        assert_eq!(keys(&next), ["fetch:musicbrainz:artist:ada", "fetch:musicbrainz:recording:r1", "fetch:musicbrainz:recording:r2"]);
        let label: Option<String> = store.read(|c| c.query_row("SELECT label FROM edition WHERE id = 1", [], |r| r.get(0))).unwrap();
        assert_eq!(label.as_deref(), Some("Fixture Label"));

        // The artist: a band they're in, and someone they worked with, neither in the library.
        let band = ExternalRef::mbid(RefKind::Agent, "band");
        let tomas = ExternalRef::mbid(RefKind::Agent, "tomas");
        let artist = Lookup { claims: vec![], threads: vec![
            thread(&ada, &band, "Fixture Band", ThreadKind::MemberOf, Some("lead vocals, 1990–1998")),
            thread(&ada, &tomas, "Tomas Vey", ThreadKind::WorkedWith, None),
        ] };
        apply(&store, &ada, artist.clone(), 2).unwrap();
        let person = store.person_page(AgentId(1)).unwrap().unwrap();
        let member_of: Vec<_> = person.member_of.iter().map(|l| (l.name.as_str(), l.detail.as_deref(), l.source.as_str())).collect();
        assert_eq!(member_of, [("Fixture Band", Some("lead vocals, 1990–1998"), PROVIDER)]);
        assert_eq!(person.linked.iter().map(|l| l.name.as_str()).collect::<Vec<_>>(), ["Tomas Vey"]);
        let band_id = person.member_of[0].agent;
        let band_page = store.person_page(band_id).unwrap().expect("a band known only from MusicBrainz has a page");
        assert_eq!(band_page.members.iter().map(|l| l.agent).collect::<Vec<_>>(), [AgentId(1)]);

        // A recording: a performer with an instrument, and the work it's of.
        let kai = ExternalRef::mbid(RefKind::Agent, "kai");
        let suite = ExternalRef::mbid(RefKind::Work, "suite");
        let (field, value) = credit("performer", &kai, "Kai Ostrander", Some("cello"));
        let recording = Lookup { claims: vec![claim(&r1, field, value)],
            threads: vec![thread(&r1, &suite, "Fixture Suite", ThreadKind::RecordingOf, None)] };
        let next = apply(&store, &r1, recording.clone(), 3).unwrap();
        assert_eq!(keys(&next), ["fetch:musicbrainz:artist:kai", "fetch:musicbrainz:work:suite"]);
        let page = store.release_page(ReleaseId(1)).unwrap().unwrap();
        let roles: Vec<_> = page.roles.iter().map(|c| (c.role.as_str(), c.name.as_str(), c.detail.as_deref(), c.source.as_str())).collect();
        assert_eq!(roles, [("performer", "Kai Ostrander", Some("cello"), PROVIDER)]);
        let work: i64 = store.read(|c| c.query_row("SELECT work_id FROM recording WHERE id = 1", [], |r| r.get(0))).unwrap();

        // The work: its composer, how many recordings MusicBrainz knows, and one you don't have.
        let live = ExternalRef::mbid(RefKind::Recording, "live");
        let ilse = ExternalRef::mbid(RefKind::Agent, "ilse");
        let mut work_lookup = Lookup::default();
        work_lookup.claims.push(claim(&suite, Field::RecordingCount, json!(12)));
        let (field, value) = credit("composer", &ilse, "Ilse Marrow", None);
        work_lookup.claims.push(claim(&suite, field, value));
        work_lookup.claims.push(claim(&live, Field::Title, json!("Fixture Suite (live)")));
        work_lookup.claims.push(claim(&live, Field::LengthMs, json!(300_000)));
        let (field, value) = credit("artist", &tomas, "Tomas Vey", None);
        work_lookup.claims.push(claim(&live, field, value));
        work_lookup.threads.push(thread(&live, &suite, "Fixture Suite", ThreadKind::RecordingOf, None));
        work_lookup.threads.push(thread(&r1, &suite, "Fixture Suite", ThreadKind::RecordingOf, None));
        apply(&store, &suite, work_lookup.clone(), 4).unwrap();
        let page = store.work_page(WorkId(work)).unwrap().unwrap();
        assert_eq!(page.recordings_known, Some(12));
        assert_eq!(page.composers.iter().map(|(_, n)| n.as_str()).collect::<Vec<_>>(), ["Ilse Marrow"]);
        let others: Vec<_> = page.others.iter().map(|o| (o.title.as_str(), o.artists.clone(), o.source.as_str())).collect();
        assert_eq!(others, [("Fixture Suite (live)", vec![(person.linked[0].agent, "Tomas Vey".to_string())], PROVIDER)]);
        assert_eq!(page.tracks.len(), 1, "your recording of it stays a track; the other one isn't");

        // Looking the same things up again adds nothing.
        let count = |sql: &str| store.read(|c| c.query_row(sql, [], |r| r.get::<_, i64>(0))).unwrap();
        let before = (count("SELECT COUNT(*) FROM credit"), count("SELECT COUNT(*) FROM edge"), count("SELECT COUNT(*) FROM recording"), count("SELECT COUNT(*) FROM agent"));
        apply(&store, &rel, release, 5).unwrap();
        apply(&store, &ada, artist, 6).unwrap();
        apply(&store, &r1, recording, 7).unwrap();
        apply(&store, &suite, work_lookup, 8).unwrap();
        assert_eq!(before, (count("SELECT COUNT(*) FROM credit"), count("SELECT COUNT(*) FROM edge"), count("SELECT COUNT(*) FROM recording"), count("SELECT COUNT(*) FROM agent")));
        drop(store);
        std::fs::remove_dir_all(dir).ok();
    }
}
