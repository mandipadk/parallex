-- Each night of the compatibility lab, kept (the lab itself publishes only
-- the latest): which version of each app was tried, and how its copy did.
-- Public, like the lab's own results; nothing about anyone's Mac.
CREATE TABLE lab_history (
    day TEXT NOT NULL,
    app TEXT NOT NULL,
    version TEXT NOT NULL DEFAULT '',
    result TEXT NOT NULL,
    PRIMARY KEY (day, app)
);
CREATE INDEX lab_history_app ON lab_history (app, day);
