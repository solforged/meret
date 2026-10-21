ALTER TABLE edge ADD COLUMN detail TEXT;
CREATE UNIQUE INDEX edge_once ON edge(from_kind, from_id, to_kind, to_id, kind);
CREATE INDEX job_kind ON job(kind, state);
ALTER TABLE work ADD COLUMN recording_count INTEGER;
