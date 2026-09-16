package schema

const appAttestRevocationDDL = `CREATE TABLE IF NOT EXISTS app_attest_key_revocations (
 key_id TEXT PRIMARY KEY REFERENCES app_attest_shadow_keys(key_id),
 account_id TEXT NOT NULL, reason TEXT NOT NULL, revoked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)`
