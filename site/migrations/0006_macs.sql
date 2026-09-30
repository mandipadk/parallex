-- Counting each Mac once: update checks from 1.7 carry a random number the
-- Mac picked once. Kept with the version, macOS and chip, never with the
-- usage report's number or an address; days are kept 90 days, and a
-- number is forgotten 90 days after its Mac last checked.
CREATE TABLE macs (
    mac TEXT PRIMARY KEY,
    first_day TEXT NOT NULL,
    last_day TEXT NOT NULL,
    version TEXT NOT NULL,
    os TEXT NOT NULL,
    arch TEXT NOT NULL,
    -- 1 when its first check was its first ever (not an older Parallex
    -- that has just started sending a number).
    fresh INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX macs_last_day ON macs (last_day);
CREATE INDEX macs_first_day ON macs (first_day);

CREATE TABLE mac_days (
    day TEXT NOT NULL,
    mac TEXT NOT NULL,
    version TEXT NOT NULL,
    PRIMARY KEY (day, mac)
);
CREATE INDEX mac_days_version ON mac_days (version, day);

-- Distinct Macs per day, kept after the rows above are gone.
CREATE TABLE mac_totals (
    day TEXT PRIMARY KEY,
    macs INTEGER NOT NULL
);
