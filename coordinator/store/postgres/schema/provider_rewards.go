package schema

func providerRewards() []string {
	return []string{

		// Base-rewards per-job settlement idempotency relies on a partial UNIQUE
		// index on provider_earnings(job_id). DAR-349: that index is built AFTER
		// this migration loop, CONCURRENTLY and at most once, by
		// ensureProviderEarningsJobIndex — NEVER with a boot-time dedupe DELETE.
		// The old `DELETE ... GROUP BY job_id` here full-scanned and locked this
		// hot table (~900k rows / ~443MB) for ~15m on deploy, blocking the
		// coordinator from binding :8080 and causing a production outage, while
		// doing no useful work (prod duplicate count is 0). Offline dedupe, if it
		// is ever needed, lives in coordinator/store/postgres/migrations/dedupe_provider_earnings.sql.

		// Base-rewards: unify sessions↔earnings identity (design §8).
		`DO $$ BEGIN ALTER TABLE provider_sessions ADD COLUMN IF NOT EXISTS provider_key TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN others THEN NULL; END $$`,
		`CREATE INDEX IF NOT EXISTS idx_provider_sessions_key ON provider_sessions(provider_key, connected_at) WHERE provider_key <> ''`,

		// Base-rewards: idempotent epoch settlement, one row per (provider_key, epoch_id).
		`CREATE TABLE IF NOT EXISTS provider_floor_draws (
			id BIGSERIAL PRIMARY KEY,
			provider_key TEXT NOT NULL,
			account_id TEXT NOT NULL DEFAULT '',
			epoch_id TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			floor_micro_usd BIGINT NOT NULL DEFAULT 0,
			earned_micro_usd BIGINT NOT NULL DEFAULT 0,
			uptime_frac DOUBLE PRECISION NOT NULL DEFAULT 0,
			memory_gb INTEGER NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			UNIQUE (provider_key, epoch_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_floor_draws_epoch ON provider_floor_draws(epoch_id)`,
		`CREATE INDEX IF NOT EXISTS idx_floor_draws_account ON provider_floor_draws(account_id, epoch_id)`,
	}
}
