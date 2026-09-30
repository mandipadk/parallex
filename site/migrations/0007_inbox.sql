-- What people send from Parallex › Something's Off: their words, what the
-- app attached (shown to them first), and a reply address only if they
-- typed one. The address goes once the note is dealt with.
CREATE TABLE feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'new',
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    -- The instance it's about, if one was picked: kind, a well-known app's
    -- bundle ID and version (else "other"), and how it has been doing.
    kind TEXT,
    app TEXT,
    app_version TEXT,
    facts TEXT NOT NULL DEFAULT '{}',
    message TEXT NOT NULL,
    contact TEXT
);
CREATE INDEX feedback_status ON feedback (status, at);

-- Notices drafted in Mission Control, published by `make notices` (which
-- signs them with the release key on the maintainer's Mac).
CREATE TABLE notice_drafts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    created TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'draft',
    bundle_id TEXT NOT NULL,
    name TEXT NOT NULL,
    versions TEXT NOT NULL,
    level TEXT NOT NULL,
    message TEXT NOT NULL,
    website TEXT,
    -- Where it came from: "apps" (a flagged version) or "feedback:<id>".
    source TEXT NOT NULL DEFAULT '',
    published TEXT
);

-- Alerts already sent, so each goes out once.
CREATE TABLE alerts_sent (
    key TEXT PRIMARY KEY,
    at TEXT NOT NULL
);
