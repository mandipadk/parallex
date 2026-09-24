-- Mission Control: counts, never people. No identifiers, no IP addresses.

-- Update checks by day. `period` says what the check was the first of on
-- that Mac: 'new' (its first ever), 'day', 'week', 'month', or 'check' (any
-- check at all). Terminal installs are counted as 'install'.
CREATE TABLE checks (
    day TEXT NOT NULL,
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    period TEXT NOT NULL,
    count INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, version, os, arch, period)
);

-- Numbers collected from GitHub (stars, issues, downloads, sponsors), one
-- value per key per day.
CREATE TABLE stats (
    day TEXT NOT NULL,
    key TEXT NOT NULL,
    value INTEGER NOT NULL,
    PRIMARY KEY (day, key)
);

-- Ko-fi support: amount and when, nothing about who.
CREATE TABLE donations (
    id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    kind TEXT NOT NULL,
    amount_cents INTEGER NOT NULL,
    currency TEXT NOT NULL,
    at TEXT NOT NULL
);
