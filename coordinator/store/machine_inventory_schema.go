package store

const machineInventoryDDL = `
CREATE TABLE IF NOT EXISTS darkbloom_machines (
 id TEXT PRIMARY KEY, assurance TEXT NOT NULL, merged_into TEXT REFERENCES darkbloom_machines(id),
 first_seen TIMESTAMPTZ NOT NULL, last_seen TIMESTAMPTZ NOT NULL
);
CREATE TABLE IF NOT EXISTS darkbloom_machine_aliases (
 kind TEXT NOT NULL, scope TEXT NOT NULL, digest TEXT NOT NULL,
 machine_id TEXT NOT NULL REFERENCES darkbloom_machines(id), verified_at TIMESTAMPTZ NOT NULL,
 PRIMARY KEY(kind,scope,digest)
);
CREATE TABLE IF NOT EXISTS darkbloom_machine_sessions (
 session_id TEXT PRIMARY KEY, machine_id TEXT NOT NULL REFERENCES darkbloom_machines(id),
 original_machine_id TEXT NOT NULL REFERENCES darkbloom_machines(id), account_id TEXT NOT NULL,
 first_seen TIMESTAMPTZ NOT NULL, last_seen TIMESTAMPTZ NOT NULL, disconnected_at TIMESTAMPTZ,
 observation JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS darkbloom_machine_sessions_seen ON darkbloom_machine_sessions(last_seen DESC);
CREATE INDEX IF NOT EXISTS darkbloom_machine_sessions_machine ON darkbloom_machine_sessions(machine_id,last_seen DESC);
CREATE TABLE IF NOT EXISTS darkbloom_machine_merges (
 source_id TEXT PRIMARY KEY REFERENCES darkbloom_machines(id), target_id TEXT NOT NULL REFERENCES darkbloom_machines(id),
 session_id TEXT NOT NULL, merged_at TIMESTAMPTZ NOT NULL, reason TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS darkbloom_machine_observations (
 session_id TEXT NOT NULL, observed_at TIMESTAMPTZ NOT NULL, observation JSONB NOT NULL,
 PRIMARY KEY(session_id,observed_at)
);
CREATE TABLE IF NOT EXISTS app_attest_shadow_events (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL, observed_at TIMESTAMPTZ NOT NULL,
 stage TEXT NOT NULL, outcome TEXT NOT NULL, fields JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS app_attest_shadow_events_session ON app_attest_shadow_events(session_id,observed_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_shadow_events_time ON app_attest_shadow_events(observed_at DESC);
`
