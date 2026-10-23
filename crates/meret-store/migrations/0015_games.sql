CREATE TABLE game (
    id         INTEGER PRIMARY KEY,
    title      TEXT NOT NULL,
    year       INTEGER,
    developers TEXT,
    platforms  TEXT,
    series     TEXT,
    series_ref TEXT,
    rev        INTEGER NOT NULL
);

-- One queue for every provider's lookups; the key names the provider.
UPDATE job SET kind = 'lookups' WHERE kind = 'musicbrainz';
