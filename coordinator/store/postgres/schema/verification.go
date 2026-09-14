package schema

func verification() []string {
	return []string{

		// Durable bounded verification scheduler. This table contains retry and
		// short claim metadata only; provider/session IDs are intentionally absent
		// and a row is never trust authority.
		`CREATE TABLE IF NOT EXISTS provider_verification_jobs (
			se_pubkey TEXT NOT NULL,
			serial TEXT NOT NULL DEFAULT '',
			udid TEXT NOT NULL DEFAULT '',
			task_kind TEXT NOT NULL,
			task_state TEXT NOT NULL,
			priority SMALLINT NOT NULL,
			retry_stage INTEGER NOT NULL DEFAULT 0,
			previous_delay_ns BIGINT NOT NULL DEFAULT 0,
			next_attempt_at TIMESTAMPTZ,
			last_outcome TEXT NOT NULL DEFAULT 'none',
			reopen_pending BOOLEAN NOT NULL DEFAULT FALSE,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			claim_owner TEXT NOT NULL DEFAULT '',
			claim_expires_at TIMESTAMPTZ,
			PRIMARY KEY (se_pubkey, task_kind)
		)`,
		`ALTER TABLE provider_verification_jobs
		 ADD COLUMN IF NOT EXISTS reopen_pending BOOLEAN NOT NULL DEFAULT FALSE`,
		`CREATE INDEX IF NOT EXISTS idx_provider_verification_jobs_due
		 ON provider_verification_jobs(priority, next_attempt_at)
		 WHERE task_state IN ('pending', 'backoff')`,
		`CREATE INDEX IF NOT EXISTS idx_provider_verification_jobs_claim
		 ON provider_verification_jobs(claim_expires_at)
		 WHERE claim_owner <> ''`,
	}
}
