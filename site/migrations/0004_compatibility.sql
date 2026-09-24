-- GitHub compatibility reports approved for the public list.
CREATE TABLE approved_reports (
    issue INTEGER PRIMARY KEY,
    bundle_id TEXT NOT NULL,
    name TEXT NOT NULL,
    app_version TEXT NOT NULL,
    verdict TEXT NOT NULL,
    url TEXT NOT NULL,
    approved_at TEXT NOT NULL
);

-- Apps the maintainer put on the public list, with the name to show. Only
-- these appear (usage reports alone can't put an app there).
CREATE TABLE listed_apps (
    bundle_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    listed_at TEXT NOT NULL
);
