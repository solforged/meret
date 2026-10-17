-- Written tag credits remain display/sort values; agents represent people.
ALTER TABLE recording ADD COLUMN artist_credit TEXT;
ALTER TABLE release ADD COLUMN album_artist_credit TEXT;
ALTER TABLE agent ADD COLUMN normalized_name TEXT;
CREATE INDEX agent_normalized_name ON agent(normalized_name);

UPDATE recording SET artist_credit = (
    SELECT group_concat(name, '; ') FROM (
        SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
        WHERE c.subject_kind = 2 AND c.subject_id = recording.id AND c.role = 'artist'
        ORDER BY c.sort, c.id
    )
);
UPDATE release SET album_artist_credit = (
    SELECT group_concat(name, '; ') FROM (
        SELECT a.name FROM credit c JOIN agent a ON a.id = c.agent_id
        WHERE c.subject_kind = 3 AND c.subject_id = release.id AND c.role = 'album_artist'
        ORDER BY c.sort, c.id
    )
);
