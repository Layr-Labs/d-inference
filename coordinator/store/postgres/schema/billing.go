package schema

func billing() []string {
	return []string{

		// Referral system tables
		`CREATE TABLE IF NOT EXISTS referrers (
			account_id TEXT PRIMARY KEY,
			code TEXT UNIQUE NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referrers_code ON referrers(code)`,

		`CREATE TABLE IF NOT EXISTS referrals (
			referred_account TEXT PRIMARY KEY,
			referrer_code TEXT NOT NULL REFERENCES referrers(code),
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`CREATE INDEX IF NOT EXISTS idx_referrals_code ON referrals(referrer_code)`,

		// Billing sessions table
		`CREATE TABLE IF NOT EXISTS billing_sessions (
			id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			payment_method TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			external_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			referral_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			completed_at TIMESTAMPTZ
		)`,
		`CREATE INDEX IF NOT EXISTS idx_billing_sessions_account ON billing_sessions(account_id)`,
		`CREATE INDEX IF NOT EXISTS idx_billing_sessions_external ON billing_sessions(external_id)`,
		`DO $$ BEGIN
			ALTER TABLE billing_sessions DROP COLUMN IF EXISTS chain;
		EXCEPTION WHEN others THEN NULL;
		END $$`,

		// Custom pricing — per-account model price overrides
		`CREATE TABLE IF NOT EXISTS model_prices (
			account_id TEXT NOT NULL,
			model TEXT NOT NULL,
			input_price BIGINT NOT NULL,
			output_price BIGINT NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (account_id, model)
		)`,

		// Clean up wallet-keyed custom prices: with the removal of wallet-based
		// payouts, model_prices rows keyed by Solana wallet addresses are
		// unreachable. Providers must re-enter custom prices under their Stripe
		// Connect account ID.
		//
		// This is a one-time, destructive cleanup, so it is gated on a
		// schema_migrations marker and runs at most once instead of on every boot.
		// Two further guards:
		//   - Exclude the synthetic "platform" account. Platform-default per-model
		//     pricing (set via PUT /v1/admin/pricing and at model registration) is
		//     stored under account_id='platform', which is NEVER a row in users.
		//     Without this guard the cleanup would wipe all platform pricing,
		//     silently reverting billing to the fallback defaults.
		//   - The marker is written only after a successful DELETE within the same
		//     block, so a run that errors (e.g. users not yet created on a brand-new
		//     DB) rolls back and is retried on the next boot.
		`DO $$ BEGIN
			IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1') THEN
				DELETE FROM model_prices
				WHERE account_id NOT IN (SELECT account_id FROM users)
				  AND account_id <> 'platform';
				INSERT INTO schema_migrations (id) VALUES ('cleanup_wallet_model_prices_v1');
			END IF;
		EXCEPTION WHEN others THEN NULL;
		END $$`,

		// Users — Privy identity → internal account mapping
		`CREATE TABLE IF NOT EXISTS users (
			account_id TEXT PRIMARY KEY,
			privy_user_id TEXT UNIQUE NOT NULL,
			email TEXT NOT NULL DEFAULT '',
			role TEXT NOT NULL DEFAULT '',
			platform_fee_percent BIGINT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
		`DO $$ BEGIN
			ALTER TABLE users ADD COLUMN IF NOT EXISTS email TEXT NOT NULL DEFAULT '';
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE users DROP COLUMN IF EXISTS solana_wallet_address;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`DO $$ BEGIN
			ALTER TABLE users DROP COLUMN IF EXISTS solana_wallet_id;
		EXCEPTION WHEN others THEN NULL;
		END $$`,
		`CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy ON users(privy_user_id)`,
	}
}
