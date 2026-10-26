-- db/migrations/001_client.sql
CREATE TABLE clients (
    username TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,

    can_read INTEGER NOT NULL DEFAULT 0
        CHECK (can_read IN (0, 1)),
    can_write INTEGER NOT NULL DEFAULT 0
        CHECK (can_write IN (0, 1)),
    can_delete INTEGER NOT NULL DEFAULT 0
        CHECK (can_delete IN (0, 1)),

    enabled INTEGER NOT NULL DEFAULT 1
        CHECK (enabled IN (0, 1)),

    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);