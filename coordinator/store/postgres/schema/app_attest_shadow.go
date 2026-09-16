package schema

const appAttestShadowDDL = `CREATE TABLE IF NOT EXISTS app_attest_shadow_keys (
	key_id TEXT PRIMARY KEY, owner TEXT NOT NULL, evidence JSONB NOT NULL,
	counter BIGINT NOT NULL DEFAULT 0 CHECK (counter >= 0 AND counter <= 4294967295),
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)`
