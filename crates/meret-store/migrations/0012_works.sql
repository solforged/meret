-- A work is found again by its title, parent and written composer, as a
-- release is by its title and album artist.
ALTER TABLE work ADD COLUMN composer_credit TEXT;
CREATE INDEX work_title ON work(title, parent_id);
CREATE INDEX recording_work ON recording(work_id);

-- Scans now read composers and the other roles, works, labels and IDs.
-- Every present file reads as changed once, and the next launch walks
-- every root instead of resuming from FSEvents, so all of them are read.
UPDATE file SET mtime_ns = -1 WHERE state = 'present';
UPDATE root SET fsevents_id = NULL;
