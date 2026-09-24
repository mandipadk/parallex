-- Opt-in usage, added into daily counts. No identifiers, no report kept.

-- How many Macs sent a report, by Parallex version.
CREATE TABLE usage_reports (
    day TEXT NOT NULL,
    version TEXT NOT NULL,
    macs INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, version)
);

-- Apps people copy: per app version and kind, how many Macs, instances,
-- Macs whose copies quit at launch, and Macs where isolation was verified.
CREATE TABLE usage_apps (
    day TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    app_version TEXT NOT NULL,
    kind TEXT NOT NULL,
    name TEXT NOT NULL,
    macs INTEGER NOT NULL DEFAULT 0,
    instances INTEGER NOT NULL DEFAULT 0,
    failing_macs INTEGER NOT NULL DEFAULT 0,
    verified_macs INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, bundle_id, app_version, kind)
);

-- Features: how many Macs use each (and in how many instances).
CREATE TABLE usage_features (
    day TEXT NOT NULL,
    feature TEXT NOT NULL,
    macs INTEGER NOT NULL DEFAULT 0,
    total INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (day, feature)
);
