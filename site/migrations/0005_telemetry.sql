-- Telemetry 2: a daily report from Macs that share usage (the default from
-- 1.6, with a switch). Each carries a random install number, renewed every
-- 180 days and tied to nothing; rows that hold it are kept 90 days, then
-- only totals without it remain. No names, paths or IP addresses.

-- One row per install number: when it was first and last seen, and what it
-- ran then. Lets counts be of Macs, not reports.
CREATE TABLE installs (
    install TEXT PRIMARY KEY,
    first_day TEXT NOT NULL,
    last_day TEXT NOT NULL,
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    -- ISO week Parallex was first used on the Mac ("2026-W40"): cohorts.
    cohort TEXT NOT NULL,
    -- 1 when this number replaced an older one (renewed every 180 days):
    -- not a new Mac.
    renewed INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX installs_last_day ON installs (last_day);
CREATE INDEX installs_version ON installs (version);

-- What happened on a Mac on a day, counted: "instance.created" with its
-- properties (kind, framework, a public app's bundle ID, result, …), and
-- the Parallex version it happened on.
CREATE TABLE events (
    day TEXT NOT NULL,
    install TEXT NOT NULL,
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    name TEXT NOT NULL,
    props TEXT NOT NULL,
    n INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, install, version, name, props)
);
CREATE INDEX events_name_day ON events (name, day);

-- What a Mac had on a day (instances, apps, features in use): one row per
-- gauge, the latest report of the day wins.
CREATE TABLE gauges (
    day TEXT NOT NULL,
    install TEXT NOT NULL,
    version TEXT NOT NULL,
    name TEXT NOT NULL,
    props TEXT NOT NULL,
    value INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, install, name, props)
);
CREATE INDEX gauges_name_day ON gauges (name, day);

-- Parallex's own crashes and hangs, by signature (offsets in its own
-- binaries only).
CREATE TABLE crashes (
    day TEXT NOT NULL,
    install TEXT NOT NULL,
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    signature TEXT NOT NULL,
    kind TEXT NOT NULL,
    n INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, install, version, signature)
);
CREATE TABLE crash_signatures (
    signature TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    summary TEXT NOT NULL,
    frames TEXT NOT NULL,
    first_day TEXT NOT NULL,
    last_day TEXT NOT NULL,
    first_version TEXT NOT NULL,
    last_version TEXT NOT NULL
);

-- Totals kept after 90 days: per day, version and event, how many installs
-- and how many times. No install numbers.
CREATE TABLE event_totals (
    day TEXT NOT NULL,
    version TEXT NOT NULL,
    name TEXT NOT NULL,
    props TEXT NOT NULL,
    installs INTEGER NOT NULL,
    total INTEGER NOT NULL,
    PRIMARY KEY (day, version, name, props)
);
CREATE TABLE install_totals (
    day TEXT NOT NULL,
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    installs INTEGER NOT NULL,
    PRIMARY KEY (day, version, os, arch)
);

-- Which install was on which version each day (from reports), for release
-- adoption and health per version; pruned with the rest at 90 days.
CREATE TABLE install_days (
    day TEXT NOT NULL,
    install TEXT NOT NULL,
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    PRIMARY KEY (day, install)
);
CREATE INDEX install_days_version ON install_days (version, day);

-- App bundle IDs and website hosts seen in reports, so that only a few new
-- ones a day are taken (the rest count as "other").
CREATE TABLE known_names (
    name TEXT PRIMARY KEY,
    first_day TEXT NOT NULL
);
CREATE INDEX known_names_first_day ON known_names (first_day);

-- What was done from Mission Control, and when: rollout changes, the public
-- list, reports reviewed.
CREATE TABLE admin_log (
    at TEXT NOT NULL,
    action TEXT NOT NULL,
    detail TEXT NOT NULL
);
CREATE INDEX admin_log_at ON admin_log (at);
