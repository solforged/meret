CREATE TABLE queue_state (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    items       TEXT NOT NULL,
    cursor      INTEGER NOT NULL,
    position_ms INTEGER NOT NULL,
    playing     INTEGER NOT NULL,
    updated_at  INTEGER NOT NULL,
    device      TEXT NOT NULL
);
