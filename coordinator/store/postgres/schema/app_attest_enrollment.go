package schema

const appAttestEnrollmentDDL = `CREATE TABLE IF NOT EXISTS app_attest_enrollments (id TEXT PRIMARY KEY,owner TEXT NOT NULL,key_id TEXT NOT NULL,created_at TIMESTAMPTZ NOT NULL,context JSONB NOT NULL)`
