-- What the scan needs: when a file joined the library, and indexes for the
-- lookups it makes for every file it reads (agents and releases by name,
-- media by disc, a track's sources). `file.state` gains 'unreadable': a file
-- whose tags couldn't be read, retried on every scan.

ALTER TABLE file ADD COLUMN added_at INTEGER;

CREATE UNIQUE INDEX root_path ON root(path);
CREATE INDEX agent_name ON agent(name);
CREATE INDEX release_title ON release(title);
CREATE INDEX edition_release ON edition(release_id);
CREATE INDEX medium_edition ON medium(edition_id, position);
CREATE INDEX track_medium ON track(medium_id);
CREATE INDEX source_track ON source(track_id);
