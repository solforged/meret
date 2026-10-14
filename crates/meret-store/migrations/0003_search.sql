-- Search, filled. Every column is written through `search_fold` (the store
-- registers it: lowercase, no accents), the same fold typed words get, and
-- rows are keyed by rowid = entity_id * 16 + entity_kind, so a scan replaces one
-- entity's row without scanning the table. Nothing wrote to it before.
-- Tracks get an index by recording, which free text and people resolve to.
--
-- * People (6): their name; the sort name in `extra`.
-- * Releases (3): the title; the album artist in `people`.
-- * Recordings (2): the title; the artist in `people`; every release it
--   is on, and those releases' album artists, in `extra`. Free text
--   matches these rows, so "iona" finds tracks by, on or called Iona.

DROP TABLE search;
CREATE VIRTUAL TABLE search USING fts5(
    entity_kind UNINDEXED,
    entity_id UNINDEXED,
    title,
    people,
    extra,
    tokenize = 'trigram remove_diacritics 1'
);
CREATE INDEX track_recording ON track(recording_id);

INSERT INTO search (rowid, entity_kind, entity_id, title, people, extra)
SELECT a.id * 16 + 6, 6, a.id, search_fold(a.name), '', search_fold(COALESCE(a.sort_name, '')) FROM agent a;

INSERT INTO search (rowid, entity_kind, entity_id, title, people, extra)
SELECT rl.id * 16 + 3, 3, rl.id, search_fold(rl.title),
       search_fold(COALESCE((SELECT group_concat(a.name, ' · ') FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 3 AND c.subject_id = rl.id), '')),
       ''
FROM release rl;

INSERT INTO search (rowid, entity_kind, entity_id, title, people, extra)
SELECT r.id * 16 + 2, 2, r.id, search_fold(r.title),
       search_fold(COALESCE((SELECT group_concat(a.name, ' · ') FROM credit c JOIN agent a ON a.id = c.agent_id
                 WHERE c.subject_kind = 2 AND c.subject_id = r.id), '')),
       search_fold(COALESCE((SELECT group_concat(x, ' · ') FROM (
                   SELECT DISTINCT rl.title AS x FROM track t JOIN medium m ON m.id = t.medium_id
                   JOIN edition e ON e.id = m.edition_id JOIN release rl ON rl.id = e.release_id
                   WHERE t.recording_id = r.id
                   UNION
                   SELECT a.name FROM track t JOIN medium m ON m.id = t.medium_id JOIN edition e ON e.id = m.edition_id
                   JOIN credit c ON c.subject_kind = 3 AND c.subject_id = e.release_id JOIN agent a ON a.id = c.agent_id
                   WHERE t.recording_id = r.id)), ''))
FROM recording r;
