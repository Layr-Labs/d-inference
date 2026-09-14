package schema

func apiKeys() []string {
	return []string{
		`CREATE TABLE IF NOT EXISTS api_keys (
			key_hash TEXT PRIMARY KEY,
			raw_prefix TEXT NOT NULL,
			owner_account_id TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			active BOOLEAN NOT NULL DEFAULT TRUE
		)`,
		`DO $$ BEGIN
			ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS owner_account_id TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		// Multi-key support: per-key id, name, limits, expiry, last-used.
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_micro_usd BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_reset TEXT NOT NULL DEFAULT 'none'; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rpm_limit BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS itpm_limit BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS otpm_limit BIGINT; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS allowed_models TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS self_route_only BOOLEAN NOT NULL DEFAULT FALSE; EXCEPTION WHEN others THEN NULL; END $$`,
		// Backfill stable IDs for legacy rows (deterministic from the hash so
		// it is stable across restarts and idempotent).
		`UPDATE api_keys SET id = 'key_' || substr(md5(key_hash), 1, 24) WHERE id IS NULL OR id = ''`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_api_keys_id ON api_keys(id) WHERE id <> ''`,
		`CREATE INDEX IF NOT EXISTS idx_api_keys_owner ON api_keys(owner_account_id) WHERE owner_account_id <> ''`,
	}
}
