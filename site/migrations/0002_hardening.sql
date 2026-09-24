-- The last good answers from GitHub, served when GitHub refuses (it limits
-- how often a shared Cloudflare address may ask).
CREATE TABLE feed (
    key TEXT PRIMARY KEY,
    body TEXT NOT NULL,
    fetched TEXT NOT NULL
);

-- Small settings: 'sessions_after' (sessions issued before it are over).
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
