package schema

func usage() []string {
	return []string{
		`CREATE TABLE IF NOT EXISTS usage (
			id BIGSERIAL PRIMARY KEY,
			provider_id TEXT NOT NULL,
			consumer_key_hash TEXT NOT NULL,
				key_id TEXT NOT NULL DEFAULT '',
				model TEXT NOT NULL,
				public_model TEXT NOT NULL DEFAULT '',
				prompt_tokens INTEGER NOT NULL,
				completion_tokens INTEGER NOT NULL,
				created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			request_id TEXT NOT NULL DEFAULT '',
			cost_micro_usd BIGINT NOT NULL DEFAULT 0,
			request_location JSONB
		)`,
		// Per-key usage attribution — ALTER for DBs upgrading from a usage
		// table created before key_id existed. Must run AFTER CREATE TABLE usage.
		`DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS key_id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS public_model TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		// Indexes for usage queries (stats, billing, per-consumer history).
		`CREATE INDEX IF NOT EXISTS idx_usage_created ON usage(created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_consumer ON usage(consumer_key_hash, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage(provider_id, created_at DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_key ON usage(key_id, created_at DESC) WHERE key_id <> ''`,
	}
}
