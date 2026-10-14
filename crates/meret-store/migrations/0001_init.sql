-- Meret library schema, v1.
--
-- Conventions
--   * Library rows have INTEGER ids assigned by the hub and a `rev` from the
--     global counter, so satellites can pull "everything since rev N".
--   * Rows a person makes (listens, notes, trails, crates, wants, resume)
--     have ULID text keys and a `device` column, and merge across devices.
--   * Facts from providers point at a `provenance` row, so every credit and
--     thread can say where it came from.
--   * Times are unix milliseconds.

PRAGMA foreign_keys = ON;

CREATE TABLE rev_counter (id INTEGER PRIMARY KEY CHECK (id = 1), rev INTEGER NOT NULL);
INSERT INTO rev_counter VALUES (1, 0);

CREATE TABLE provenance (
    id           INTEGER PRIMARY KEY,
    source       TEXT NOT NULL,            -- musicbrainz, vgmdb, local_audio, you…
    external_ref TEXT,
    fetched_at   INTEGER NOT NULL,
    confidence   REAL NOT NULL DEFAULT 1.0
);

-- The music ------------------------------------------------------------------

CREATE TABLE agent (
    id        INTEGER PRIMARY KEY,
    kind      INTEGER NOT NULL,            -- 0 person, 1 group
    name      TEXT NOT NULL,
    sort_name TEXT,
    origin    TEXT,
    rev       INTEGER NOT NULL
);

CREATE TABLE work (
    id         INTEGER PRIMARY KEY,
    parent_id  INTEGER REFERENCES work(id),   -- movements, variations, parts
    position   INTEGER,
    title      TEXT NOT NULL,
    catalogue  TEXT,                          -- BWV 988, Op. 92
    rev        INTEGER NOT NULL
);

CREATE TABLE recording (
    id         INTEGER PRIMARY KEY,
    work_id    INTEGER REFERENCES work(id),
    title      TEXT NOT NULL,
    length_ms  INTEGER,
    recorded   TEXT,                          -- a date or a partial date
    venue      TEXT,
    rev        INTEGER NOT NULL
);

CREATE TABLE release (
    id            INTEGER PRIMARY KEY,
    title         TEXT NOT NULL,
    year          INTEGER,
    idiom         INTEGER,                    -- meret_model::Idiom
    idiom2        INTEGER,                    -- a second idiom, if any
    idiom_source  TEXT,                       -- you, musicbrainz, local_audio, structure
    rev           INTEGER NOT NULL
);

CREATE TABLE edition (
    id          INTEGER PRIMARY KEY,
    release_id  INTEGER NOT NULL REFERENCES release(id),
    title       TEXT,
    year        INTEGER,
    label       TEXT,
    catalog_no  TEXT,
    dr          INTEGER,                      -- dynamic range, per edition
    is_default  INTEGER NOT NULL DEFAULT 0,
    rev         INTEGER NOT NULL
);

CREATE TABLE medium (
    id          INTEGER PRIMARY KEY,
    edition_id  INTEGER NOT NULL REFERENCES edition(id),
    position    INTEGER NOT NULL,
    format      TEXT
);

CREATE TABLE track (
    id            INTEGER PRIMARY KEY,
    medium_id     INTEGER NOT NULL REFERENCES medium(id),
    position      INTEGER NOT NULL,
    recording_id  INTEGER NOT NULL REFERENCES recording(id),
    title         TEXT,
    length_ms     INTEGER,
    rev           INTEGER NOT NULL
);

CREATE TABLE credit (
    id            INTEGER PRIMARY KEY,
    subject_kind  INTEGER NOT NULL,           -- meret_model::EntityKind
    subject_id    INTEGER NOT NULL,
    agent_id      INTEGER NOT NULL REFERENCES agent(id),
    role          TEXT NOT NULL,
    detail        TEXT,                       -- "2-16, 2-17", "uilleann pipes"
    sort          INTEGER NOT NULL DEFAULT 0,
    provenance_id INTEGER REFERENCES provenance(id),
    rev           INTEGER NOT NULL
);
CREATE INDEX credit_subject ON credit(subject_kind, subject_id);
CREATE INDEX credit_agent ON credit(agent_id, role);

CREATE TABLE context (
    id     INTEGER PRIMARY KEY,
    title  TEXT NOT NULL,                     -- "Fei's village", "ending credits"
    kind   TEXT,                              -- area, scene, boss, set
    rev    INTEGER NOT NULL
);
CREATE TABLE recording_context (
    recording_id  INTEGER NOT NULL REFERENCES recording(id),
    context_id    INTEGER NOT NULL REFERENCES context(id),
    provenance_id INTEGER REFERENCES provenance(id),
    PRIMARY KEY (recording_id, context_id)
);

CREATE TABLE external_id (
    entity_kind INTEGER NOT NULL,
    entity_id   INTEGER NOT NULL,
    namespace   TEXT NOT NULL,                -- mbid, isrc, discogs, vgmdb, spotify…
    value       TEXT NOT NULL,
    PRIMARY KEY (namespace, value, entity_kind)
);
CREATE INDEX external_id_entity ON external_id(entity_kind, entity_id);

-- Threads: typed, sourced relations ------------------------------------------

CREATE TABLE edge (
    id            INTEGER PRIMARY KEY,
    from_kind     INTEGER NOT NULL,
    from_id       INTEGER NOT NULL,
    to_kind       INTEGER NOT NULL,
    to_id         INTEGER NOT NULL,
    kind          TEXT NOT NULL,              -- meret_model::ThreadKind, snake_case
    weight        REAL NOT NULL DEFAULT 1.0,  -- similarity for sounds_like
    provenance_id INTEGER REFERENCES provenance(id),
    rev           INTEGER NOT NULL
);
CREATE INDEX edge_from ON edge(from_kind, from_id, kind);
CREATE INDEX edge_to ON edge(to_kind, to_id, kind);

-- Where bytes come from ------------------------------------------------------

CREATE TABLE root (
    id            INTEGER PRIMARY KEY,
    volume_uuid   TEXT,                       -- survives remounts and renames
    label         TEXT NOT NULL,
    path          TEXT NOT NULL,
    kind          TEXT NOT NULL,              -- local, smb, nfs
    state         TEXT NOT NULL DEFAULT 'online',
    fsevents_id   INTEGER,                    -- resume point for the watcher
    last_walk_at  INTEGER
);

CREATE TABLE file (
    id            INTEGER PRIMARY KEY,
    root_id       INTEGER NOT NULL REFERENCES root(id),
    rel_path      TEXT NOT NULL,
    size          INTEGER NOT NULL,
    mtime_ns      INTEGER NOT NULL,
    inode         INTEGER,
    head_hash     BLOB,                       -- blake3 of the first 64 KiB, for move detection
    state         TEXT NOT NULL DEFAULT 'present',   -- present, missing, offline
    rev           INTEGER NOT NULL,
    UNIQUE (root_id, rel_path)
);
CREATE INDEX file_move ON file(size, head_hash);

CREATE TABLE source (
    id           INTEGER PRIMARY KEY,
    recording_id INTEGER REFERENCES recording(id),
    track_id     INTEGER REFERENCES track(id),
    kind         TEXT NOT NULL,               -- file, stream, zone
    file_id      INTEGER REFERENCES file(id),
    cue_index    INTEGER,                     -- a track inside a single-file image
    uri          TEXT,                        -- spotify:track:…, bandcamp://…
    provider     TEXT,
    codec        TEXT,
    sample_rate  INTEGER,
    bits         INTEGER,
    channels     INTEGER,
    lossless     INTEGER NOT NULL DEFAULT 0,
    length_ms    INTEGER,
    loop_start   INTEGER,                     -- frames
    loop_end     INTEGER,
    rip_verified TEXT,                        -- accuraterip, ctdb, or null
    rev          INTEGER NOT NULL
);
CREATE INDEX source_recording ON source(recording_id);
CREATE INDEX source_file ON source(file_id);

CREATE TABLE identity (
    source_id    INTEGER PRIMARY KEY REFERENCES source(id),
    method       TEXT NOT NULL,               -- manual, mbid_tag, isrc, acoustid, fuzzy
    confidence   REAL NOT NULL,
    evidence     TEXT,                        -- JSON: what matched and how well
    decided_at   INTEGER NOT NULL
);

CREATE TABLE artwork (
    hash           BLOB PRIMARY KEY,          -- blake3 of the original image
    width          INTEGER,
    height         INTEGER,
    light          INTEGER,                   -- ARGB, clamped in OKLCH; null for pale covers
    light_wash     INTEGER,
    light_dim      INTEGER
);
CREATE TABLE entity_artwork (
    entity_kind INTEGER NOT NULL,
    entity_id   INTEGER NOT NULL,
    hash        BLOB NOT NULL REFERENCES artwork(hash),
    PRIMARY KEY (entity_kind, entity_id)
);

-- Analysis summaries; vectors live in embeddings.f16, not here.
CREATE TABLE analysis (
    recording_id   INTEGER PRIMARY KEY REFERENCES recording(id),
    loudness_lufs  REAL,
    peak_db        REAL,
    dr             INTEGER,
    bpm            REAL,
    key            TEXT,
    body           BLOB,                      -- meret_analysis::BodySummary, packed
    embedding_row  INTEGER,
    analysed_at    INTEGER NOT NULL,
    version        INTEGER NOT NULL
);

-- Podcasts -------------------------------------------------------------------

CREATE TABLE feed (
    id     INTEGER PRIMARY KEY,
    url    TEXT NOT NULL UNIQUE,
    title  TEXT NOT NULL,
    rev    INTEGER NOT NULL
);
CREATE TABLE episode (
    id          INTEGER PRIMARY KEY,
    feed_id     INTEGER NOT NULL REFERENCES feed(id),
    guid        TEXT NOT NULL,
    title       TEXT NOT NULL,
    published   INTEGER,
    length_ms   INTEGER,
    chapters    TEXT,                         -- JSON, Podcasting 2.0
    transcript  TEXT,
    rev         INTEGER NOT NULL,
    UNIQUE (feed_id, guid)
);

-- What a person makes (ULIDs, merged across devices) -------------------------

CREATE TABLE listen (
    uid           TEXT PRIMARY KEY,
    recording_id  INTEGER,
    episode_id    INTEGER,
    source_id     INTEGER,
    zone          TEXT,
    started_at    INTEGER NOT NULL,
    played_ms     INTEGER NOT NULL,
    from_stop     TEXT,                       -- the trail stop it was played from
    device        TEXT NOT NULL
);
CREATE INDEX listen_recording ON listen(recording_id, started_at);
CREATE INDEX listen_time ON listen(started_at);

CREATE TABLE note (
    uid          TEXT PRIMARY KEY,
    subject_kind INTEGER NOT NULL,
    subject_id   INTEGER NOT NULL,
    at_ms        INTEGER,                     -- a moment in the recording
    body         TEXT NOT NULL,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    device       TEXT NOT NULL
);
CREATE INDEX note_subject ON note(subject_kind, subject_id);

CREATE TABLE trail (
    uid          TEXT PRIMARY KEY,
    name         TEXT,
    root_query   TEXT,                        -- the search that started it, if any
    kept         INTEGER NOT NULL DEFAULT 0,
    created_at   INTEGER NOT NULL,
    current_stop TEXT,
    device       TEXT NOT NULL
);

-- Stops are append-only, so merging trails from two devices is a union.
CREATE TABLE stop (
    uid          TEXT PRIMARY KEY,
    trail_uid    TEXT NOT NULL REFERENCES trail(uid),
    parent_uid   TEXT REFERENCES stop(uid),
    entity_kind  INTEGER NOT NULL,
    entity_id    TEXT NOT NULL,               -- text so crates and trails (ULIDs) fit too
    via_kind     TEXT,                        -- the thread followed to get here
    via_source   TEXT,
    opened_at    INTEGER NOT NULL,
    dwell_ms     INTEGER NOT NULL DEFAULT 0,
    device       TEXT NOT NULL
);
CREATE INDEX stop_trail ON stop(trail_uid, opened_at);

CREATE TABLE stop_action (
    stop_uid  TEXT NOT NULL REFERENCES stop(uid),
    action    TEXT NOT NULL,                  -- played, wanted, crated, noted
    at        INTEGER NOT NULL,
    detail    TEXT
);

CREATE TABLE crate (
    uid         TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    kind        TEXT NOT NULL,                -- set, ordered, rule
    rule        TEXT,                         -- a meret-query string
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    device      TEXT NOT NULL
);
CREATE TABLE crate_item (
    crate_uid    TEXT NOT NULL REFERENCES crate(uid),
    position     TEXT NOT NULL,               -- fractional index, so concurrent inserts merge
    entity_kind  INTEGER NOT NULL,
    entity_id    TEXT NOT NULL,
    added_at     INTEGER NOT NULL,
    PRIMARY KEY (crate_uid, position)
);

CREATE TABLE want (
    uid          TEXT PRIMARY KEY,
    entity_kind  INTEGER NOT NULL,
    entity_id    TEXT NOT NULL,
    from_stop    TEXT,
    state        TEXT NOT NULL DEFAULT 'open', -- open, found, bought, dropped
    created_at   INTEGER NOT NULL,
    device       TEXT NOT NULL
);

-- "Pick up where you left off", one row per thing partway through.
CREATE TABLE resume (
    subject_kind INTEGER NOT NULL,
    subject_id   INTEGER NOT NULL,
    recording_id INTEGER,
    position_ms  INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    device       TEXT NOT NULL,
    PRIMARY KEY (subject_kind, subject_id)
);

-- Machinery ------------------------------------------------------------------

CREATE TABLE job (
    id          INTEGER PRIMARY KEY,
    kind        TEXT NOT NULL,
    dedupe_key  TEXT UNIQUE,                  -- e.g. "analyse:recording:42"
    priority    INTEGER NOT NULL DEFAULT 0,
    state       TEXT NOT NULL DEFAULT 'queued', -- queued, running, done, failed, paused
    attempts    INTEGER NOT NULL DEFAULT 0,
    run_after   INTEGER NOT NULL DEFAULT 0,
    progress    REAL,
    payload     TEXT,
    last_error  TEXT,
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL
);
CREATE INDEX job_ready ON job(state, priority DESC, run_after);

CREATE TABLE provider_state (
    provider TEXT NOT NULL,
    key      TEXT NOT NULL,
    value    TEXT,
    PRIMARY KEY (provider, key)
);

-- Search. Trigram so CJK titles and partial words both match.
CREATE VIRTUAL TABLE search USING fts5(
    entity_kind UNINDEXED,
    entity_id UNINDEXED,
    title,
    people,
    extra,
    tokenize = 'trigram'
);
