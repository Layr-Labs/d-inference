package schema

func ledger(rewardTypesSQL string) []string {
	return []string{

		`CREATE TABLE IF NOT EXISTS payments (
			id BIGSERIAL PRIMARY KEY,
			tx_hash TEXT UNIQUE,
			consumer_address TEXT NOT NULL,
			provider_address TEXT NOT NULL,
			amount_usd TEXT NOT NULL,
			model TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL,
			completion_tokens INTEGER NOT NULL,
			memo TEXT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS balances (
			account_id TEXT PRIMARY KEY,
			balance_micro_usd BIGINT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE TABLE IF NOT EXISTS ledger_entries (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT NOT NULL,
			entry_type TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			balance_after BIGINT NOT NULL,
			reference TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_ledger_account ON ledger_entries(account_id, created_at DESC)`,
		// Partial index for the public leaderboard/network-totals reward scans,
		// which filter ledger_entries by reward entry_type across all accounts.
		// Without it, each cache miss seq-scans the whole (multi-million-row)
		// ledger to find the handful of reward rows. Predicate is derived from
		// RewardLedgerTypes so it matches the query's IN-list exactly.
		`CREATE INDEX IF NOT EXISTS idx_ledger_reward ON ledger_entries(account_id, created_at DESC) WHERE entry_type IN (` + rewardTypesSQL + `)`,
	}
}
