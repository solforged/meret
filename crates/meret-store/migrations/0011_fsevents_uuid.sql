-- The FSEvents database the stored event id belongs to. A different UUID
-- means the volume's event history was reset, so the id means nothing.
ALTER TABLE root ADD COLUMN fsevents_uuid TEXT;
