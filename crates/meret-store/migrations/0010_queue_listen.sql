-- The listen still open when the queue was saved, so resuming after a
-- restart continues it rather than counting the same play twice.
ALTER TABLE queue_state ADD COLUMN listen TEXT;
