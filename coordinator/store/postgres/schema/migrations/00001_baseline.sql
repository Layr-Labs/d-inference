-- Baseline: the 255 statements that (*PostgresStore).migrate ran on every
-- boot before goose, in the same order (see postgres.go and the DDL constants
-- at commit 48d2be45 for their history). Broad exception handlers are removed
-- so a failed statement cannot be recorded as applied. Each block runs as one
-- call outside a transaction, as before. On a database that already has this
-- schema existing data and object definitions are preserved. Do not edit this
-- file; add a new numbered migration instead (docs/developer/database-migrations.md).
-- +goose NO TRANSACTION
-- +goose Up
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS global_payout_recipients (
 account_id TEXT PRIMARY KEY, country TEXT NOT NULL, data JSONB NOT NULL
);
CREATE TABLE IF NOT EXISTS global_payout_withdrawals (
 id TEXT PRIMARY KEY, account_id TEXT NOT NULL, status TEXT NOT NULL,
 external_id TEXT NOT NULL DEFAULT '', submitted_at TIMESTAMPTZ NOT NULL,
 checked_at TIMESTAMPTZ NOT NULL, lease_until TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL, data JSONB NOT NULL
);
ALTER TABLE global_payout_withdrawals ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ NOT NULL DEFAULT 'infinity';
UPDATE global_payout_withdrawals SET expires_at=(data->>'expires_at')::timestamptz WHERE status='quoted' AND expires_at='infinity';
CREATE INDEX IF NOT EXISTS global_payout_quote_expiry ON global_payout_withdrawals(expires_at) WHERE status='quoted';
CREATE UNIQUE INDEX IF NOT EXISTS global_payout_external_id ON global_payout_withdrawals(external_id) WHERE external_id <> '';
CREATE INDEX IF NOT EXISTS global_payout_account ON global_payout_withdrawals(account_id, submitted_at DESC);
CREATE INDEX IF NOT EXISTS global_payout_reconcile ON global_payout_withdrawals(checked_at) WHERE status IN ('pending','processing','posted');
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS providers (
			id TEXT PRIMARY KEY,
			hardware JSONB NOT NULL,
			models JSONB NOT NULL,
			backend TEXT NOT NULL,
			location JSONB,
			registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			trust_level TEXT NOT NULL DEFAULT 'none',
			attested BOOLEAN NOT NULL DEFAULT FALSE,
			attestation_result JSONB,
			se_public_key TEXT NOT NULL DEFAULT '',
			public_key TEXT NOT NULL DEFAULT '',
			serial_number TEXT NOT NULL DEFAULT '',
			mda_verified BOOLEAN NOT NULL DEFAULT FALSE,
			mda_cert_chain JSONB,
			version TEXT NOT NULL DEFAULT '',
			runtime_verified BOOLEAN NOT NULL DEFAULT FALSE,
			python_hash TEXT NOT NULL DEFAULT '',
			runtime_hash TEXT NOT NULL DEFAULT '',
			last_challenge_verified TIMESTAMPTZ,
			failed_challenges INT NOT NULL DEFAULT 0,
			account_id TEXT NOT NULL DEFAULT '',
			lifetime_requests_served BIGINT NOT NULL DEFAULT 0,
			lifetime_tokens_generated BIGINT NOT NULL DEFAULT 0,
			last_session_requests_served BIGINT NOT NULL DEFAULT 0,
			last_session_tokens_generated BIGINT NOT NULL DEFAULT 0,
			lifetime_stats JSONB NOT NULL DEFAULT '{}'::jsonb,
			last_session_stats JSONB NOT NULL DEFAULT '{}'::jsonb
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS location JSONB;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS trust_level TEXT NOT NULL DEFAULT 'none';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS attested BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS attestation_result JSONB;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS se_public_key TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS public_key TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS serial_number TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS mda_verified BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS mda_cert_chain JSONB;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS version TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS runtime_verified BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS python_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS runtime_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_challenge_verified TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS failed_challenges INT NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS account_id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_requests_served BIGINT NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_tokens_generated BIGINT NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_requests_served BIGINT NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_tokens_generated BIGINT NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_stats JSONB NOT NULL DEFAULT '{}'::jsonb;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_stats JSONB NOT NULL DEFAULT '{}'::jsonb;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_providers_serial ON providers(serial_number) WHERE serial_number != '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_providers_account ON providers(account_id, last_seen DESC) WHERE account_id != '';
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS request_id TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN undefined_table THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS cost_micro_usd BIGINT NOT NULL DEFAULT 0; EXCEPTION WHEN undefined_table THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS request_location JSONB; EXCEPTION WHEN undefined_table THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE usage ADD COLUMN IF NOT EXISTS public_model TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN undefined_table THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_reputation (
			provider_id TEXT PRIMARY KEY REFERENCES providers(id),
			total_jobs INT NOT NULL DEFAULT 0,
			successful_jobs INT NOT NULL DEFAULT 0,
			failed_jobs INT NOT NULL DEFAULT 0,
			total_uptime_seconds BIGINT NOT NULL DEFAULT 0,
			avg_response_time_ms BIGINT NOT NULL DEFAULT 0,
			challenges_passed INT NOT NULL DEFAULT 0,
			challenges_failed INT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS api_keys (
			key_hash TEXT PRIMARY KEY,
			raw_prefix TEXT NOT NULL,
			owner_account_id TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			active BOOLEAN NOT NULL DEFAULT TRUE
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS owner_account_id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_micro_usd BIGINT;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_reset TEXT NOT NULL DEFAULT 'none';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rpm_limit BIGINT;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS itpm_limit BIGINT;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS otpm_limit BIGINT;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS allowed_models TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS self_route_only BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
UPDATE api_keys SET id = 'key_' || substr(md5(key_hash), 1, 24) WHERE id IS NULL OR id = '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE UNIQUE INDEX IF NOT EXISTS idx_api_keys_id ON api_keys(id) WHERE id <> '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_api_keys_owner ON api_keys(owner_account_id) WHERE owner_account_id <> '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS usage (
			id BIGSERIAL PRIMARY KEY,
			provider_id TEXT NOT NULL,
			consumer_key_hash TEXT NOT NULL,
				key_id TEXT NOT NULL DEFAULT '',
				model TEXT NOT NULL,
				public_model TEXT NOT NULL DEFAULT '',
				prompt_tokens INTEGER NOT NULL,
				cached_tokens INTEGER NOT NULL DEFAULT 0,
				completion_tokens INTEGER NOT NULL,
				created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			request_id TEXT NOT NULL DEFAULT '',
			cost_micro_usd BIGINT NOT NULL DEFAULT 0,
			request_location JSONB
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE usage ADD COLUMN IF NOT EXISTS key_id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE usage ADD COLUMN IF NOT EXISTS public_model TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE usage ADD COLUMN IF NOT EXISTS cached_tokens INTEGER NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_usage_created ON usage(created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_usage_consumer ON usage(consumer_key_hash, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage(provider_id, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_usage_key ON usage(key_id, created_at DESC) WHERE key_id <> '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS payments (
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
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS balances (
			account_id TEXT PRIMARY KEY,
			balance_micro_usd BIGINT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS ledger_entries (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT NOT NULL,
			entry_type TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			balance_after BIGINT NOT NULL,
			reference TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_ledger_account ON ledger_entries(account_id, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_ledger_reward ON ledger_entries(account_id, created_at DESC) WHERE entry_type IN ('referral_reward','admin_reward');
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS referrers (
			account_id TEXT PRIMARY KEY,
			code TEXT UNIQUE NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_referrers_code ON referrers(code);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS referrals (
			referred_account TEXT PRIMARY KEY,
			referrer_code TEXT NOT NULL REFERENCES referrers(code),
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_referrals_code ON referrals(referrer_code);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS billing_sessions (
			id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			payment_method TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			external_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			referral_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			completed_at TIMESTAMPTZ
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_billing_sessions_account ON billing_sessions(account_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_billing_sessions_external ON billing_sessions(external_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_prices (
			account_id TEXT NOT NULL,
			model TEXT NOT NULL,
			input_price BIGINT NOT NULL,
			output_price BIGINT NOT NULL,
			cache_read_price BIGINT,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (account_id, model)
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_prices ADD COLUMN IF NOT EXISTS cache_read_price BIGINT;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS users (
			account_id TEXT PRIMARY KEY,
			privy_user_id TEXT UNIQUE NOT NULL,
			email TEXT NOT NULL DEFAULT '',
			role TEXT NOT NULL DEFAULT '',
			platform_fee_percent BIGINT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS email TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy ON users(privy_user_id);
-- +goose StatementEnd
-- +goose StatementBegin
DROP TABLE IF EXISTS supported_models;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_registry (
			id TEXT PRIMARY KEY,
			display_name TEXT NOT NULL,
			family TEXT NOT NULL DEFAULT '',
			architecture TEXT NOT NULL DEFAULT '',
			quantization TEXT NOT NULL DEFAULT '',
			max_context_length INTEGER NOT NULL DEFAULT 0,
			max_output_length INTEGER NOT NULL DEFAULT 0,
			min_ram_gb INTEGER NOT NULL DEFAULT 0,
			capabilities TEXT[] NOT NULL DEFAULT '{}',
			required_provider_capabilities TEXT[] NOT NULL DEFAULT '{}',
			status TEXT NOT NULL DEFAULT 'beta',
			description TEXT NOT NULL DEFAULT '',
			runtime_parameters JSONB NOT NULL DEFAULT '{}',
			metadata JSONB NOT NULL DEFAULT '{}',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_model_registry_status ON model_registry(status);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_versions (
			id BIGSERIAL PRIMARY KEY,
			model_id TEXT NOT NULL REFERENCES model_registry(id) ON DELETE CASCADE,
			version TEXT NOT NULL,
			r2_prefix TEXT NOT NULL,
			aggregate_sha256 TEXT NOT NULL,
			total_size_bytes BIGINT NOT NULL,
			file_count INTEGER NOT NULL,
			status TEXT NOT NULL DEFAULT 'ready',
			uploaded_by TEXT NOT NULL DEFAULT '',
			uploaded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			promoted_at TIMESTAMPTZ,
			metadata JSONB NOT NULL DEFAULT '{}',
			UNIQUE(model_id, version)
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_versions ADD COLUMN IF NOT EXISTS hugging_face_artifact JSONB;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_context_length INTEGER NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_output_length INTEGER NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS runtime_parameters JSONB NOT NULL DEFAULT '{}';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS required_provider_capabilities TEXT[] NOT NULL DEFAULT '{}';
-- +goose StatementEnd
-- +goose StatementBegin
UPDATE model_registry
		 SET required_provider_capabilities = (
		   SELECT ARRAY_AGG(DISTINCT capability ORDER BY capability)
		   FROM UNNEST(required_provider_capabilities ||
		     ARRAY['apple_m5', 'mlx_nax']::TEXT[]) AS capability
		 )
		 WHERE id = 'EigenLabs/Qwen3.8-27B-4bit'
		   AND NOT (required_provider_capabilities @>
		     ARRAY['apple_m5', 'mlx_nax']::TEXT[]);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_model_versions_model ON model_versions(model_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_version_files (
			id BIGSERIAL PRIMARY KEY,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE CASCADE,
			path TEXT NOT NULL,
			size_bytes BIGINT NOT NULL,
			sha256 TEXT NOT NULL,
			role TEXT NOT NULL,
			UNIQUE(model_version_id, path)
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_model_version_files_version ON model_version_files(model_version_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_active_versions (
			model_id TEXT PRIMARY KEY REFERENCES model_registry(id) ON DELETE CASCADE,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE RESTRICT,
			activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS publishing_api_keys (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			key_hash TEXT NOT NULL,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_used_at TIMESTAMPTZ
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_api_keys_hash ON publishing_api_keys(key_hash);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_aliases (
			alias_id TEXT PRIMARY KEY,
			display_name TEXT NOT NULL DEFAULT '',
			builds JSONB NOT NULL DEFAULT '[]'::jsonb,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS desired_build TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS previous_build TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS retired_builds JSONB NOT NULL DEFAULT '[]'::jsonb;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS openrouter_only BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS source_model TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS source_kind TEXT NOT NULL DEFAULT 'standard_alias';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS openrouter_slug TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS hugging_face_id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
UPDATE model_aliases a
			SET desired_build = sub.build_id
			FROM (
				SELECT DISTINCT ON (alias_id) alias_id, (b->>'build_id') AS build_id
				FROM model_aliases, jsonb_array_elements(builds) AS b
				WHERE COALESCE((b->>'active')::boolean, true)
				  AND COALESCE((b->>'weight')::int, 0) > 0
				ORDER BY alias_id, COALESCE((b->>'weight')::int, 0) DESC
			) sub
			WHERE a.alias_id = sub.alias_id AND a.desired_build = '';
-- +goose StatementEnd
-- +goose StatementBegin
DROP TABLE IF EXISTS model_migrations;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS releases (
			version TEXT NOT NULL,
			platform TEXT NOT NULL,
			backend TEXT NOT NULL DEFAULT '',
			binary_hash TEXT NOT NULL DEFAULT '',
			bundle_hash TEXT NOT NULL DEFAULT '',
			metallib_hash TEXT NOT NULL DEFAULT '',
			python_hash TEXT NOT NULL DEFAULT '',
			runtime_hash TEXT NOT NULL DEFAULT '',
			template_hashes TEXT NOT NULL DEFAULT '',
			grpc_binary_hash TEXT NOT NULL DEFAULT '',
			url TEXT NOT NULL DEFAULT '',
			changelog TEXT NOT NULL DEFAULT '',
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (version, platform)
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE releases ADD COLUMN IF NOT EXISTS backend TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE releases ADD COLUMN IF NOT EXISTS metallib_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE releases ADD COLUMN IF NOT EXISTS changelog TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE releases ADD COLUMN IF NOT EXISTS python_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE releases ADD COLUMN IF NOT EXISTS runtime_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE releases ADD COLUMN IF NOT EXISTS template_hashes TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE releases ADD COLUMN IF NOT EXISTS grpc_binary_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS device_codes (
			device_code TEXT PRIMARY KEY,
			user_code TEXT UNIQUE NOT NULL,
			account_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			expires_at TIMESTAMPTZ NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_device_codes_user ON device_codes(user_code);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_tokens (
			token_hash TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			label TEXT NOT NULL DEFAULT '',
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_tokens_account ON provider_tokens(account_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS invite_codes (
			code TEXT PRIMARY KEY,
			amount_micro_usd BIGINT NOT NULL,
			max_uses INTEGER NOT NULL DEFAULT 1,
			used_count INTEGER NOT NULL DEFAULT 0,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			expires_at TIMESTAMPTZ,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS invite_redemptions (
			code TEXT NOT NULL REFERENCES invite_codes(code),
			account_id TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (code, account_id)
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_earnings (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT NOT NULL,
			provider_id TEXT NOT NULL,
			provider_key TEXT NOT NULL DEFAULT '',
			job_id TEXT NOT NULL,
			model TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			prompt_tokens INTEGER NOT NULL DEFAULT 0,
			completion_tokens INTEGER NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_earnings_account ON provider_earnings(account_id, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_earnings_provider ON provider_earnings(provider_key, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS earnings_summary (
			key TEXT NOT NULL,
			key_type TEXT NOT NULL,
			total_count BIGINT NOT NULL DEFAULT 0,
			total_micro_usd BIGINT NOT NULL DEFAULT 0,
			total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
			total_completion_tokens BIGINT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (key, key_type)
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_payouts (
			id BIGSERIAL PRIMARY KEY,
			provider_address TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			model TEXT NOT NULL DEFAULT '',
			job_id TEXT NOT NULL DEFAULT '',
			settled BOOLEAN NOT NULL DEFAULT FALSE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_payouts_address ON provider_payouts(provider_address, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_payouts_settled ON provider_payouts(settled, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_status TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_country TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_destination_type TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_destination_last4 TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_instant_eligible BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE UNIQUE INDEX IF NOT EXISTS idx_users_stripe_account ON users(stripe_account_id) WHERE stripe_account_id != '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE users ADD COLUMN IF NOT EXISTS platform_fee_percent BIGINT;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS stripe_withdrawals (
			id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			stripe_account_id TEXT NOT NULL,
			transfer_id TEXT NOT NULL DEFAULT '',
			payout_id TEXT NOT NULL DEFAULT '',
			amount_micro_usd BIGINT NOT NULL,
			fee_micro_usd BIGINT NOT NULL DEFAULT 0,
			net_micro_usd BIGINT NOT NULL,
			method TEXT NOT NULL,
			status TEXT NOT NULL,
			failure_reason TEXT NOT NULL DEFAULT '',
			refunded BOOLEAN NOT NULL DEFAULT FALSE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_account ON stripe_withdrawals(account_id, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_withdrawals_transfer ON stripe_withdrawals(transfer_id) WHERE transfer_id != '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_withdrawals_payout ON stripe_withdrawals(payout_id) WHERE payout_id != '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_status ON stripe_withdrawals(status, created_at);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_stripe_account ON stripe_withdrawals(stripe_account_id, status);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS fee_refunded BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS sweep_payout_id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_sweep_payout ON stripe_withdrawals(sweep_payout_id) WHERE sweep_payout_id != '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS usage_totals (
			id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
			total_requests BIGINT NOT NULL DEFAULT 0,
			total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
			total_completion_tokens BIGINT NOT NULL DEFAULT 0
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_usage_request_location_notnull ON usage(created_at DESC) WHERE request_location IS NOT NULL;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_log_reports (
			id BIGSERIAL PRIMARY KEY,
			serial_number TEXT NOT NULL DEFAULT '',
			provider_id TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			log_data BYTEA NOT NULL,
			log_size_bytes BIGINT NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_log_reports ALTER COLUMN serial_number SET DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION clear_provider_log_report_serial()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
	NEW.serial_number := '';
	RETURN NEW;
END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN
	IF NOT EXISTS (
		SELECT 1
		FROM pg_trigger tg
		JOIN pg_class target ON target.oid = tg.tgrelid
		JOIN pg_namespace ns ON ns.oid = target.relnamespace
		WHERE tg.tgname = 'clear_provider_log_report_serial'
		  AND NOT tg.tgisinternal
		  AND target.relname = 'provider_log_reports'
		  AND ns.nspname = current_schema()
	) THEN
		CREATE TRIGGER clear_provider_log_report_serial
		BEFORE INSERT OR UPDATE OF serial_number ON provider_log_reports
		FOR EACH ROW EXECUTE FUNCTION clear_provider_log_report_serial();
	END IF;
END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN
	IF NOT EXISTS (
		SELECT 1 FROM schema_migrations
		WHERE id = 'scrub_provider_log_report_serials_v1'
	) THEN
		UPDATE provider_log_reports SET serial_number = '' WHERE serial_number <> '';
		INSERT INTO schema_migrations (id)
		VALUES ('scrub_provider_log_report_serials_v1')
		ON CONFLICT (id) DO NOTHING;
	END IF;
END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DROP INDEX IF EXISTS idx_log_reports_serial;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_sessions (
			id BIGSERIAL PRIMARY KEY,
			session_id TEXT NOT NULL UNIQUE,
			serial_number TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			connected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			disconnected_at TIMESTAMPTZ,
			disconnect_reason TEXT NOT NULL DEFAULT ''
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_sessions_serial ON provider_sessions(serial_number, connected_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_sessions_connected ON provider_sessions(connected_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_sessions_open ON provider_sessions(connected_at) WHERE disconnected_at IS NULL;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS inference_routes (
			id BIGSERIAL PRIMARY KEY,
			request_id TEXT NOT NULL,
			attempt INTEGER NOT NULL DEFAULT 0,
			provider_id TEXT NOT NULL DEFAULT '',
			model TEXT NOT NULL,
			public_model TEXT NOT NULL DEFAULT '',
			consumer_key_hash TEXT NOT NULL DEFAULT '',
			key_id TEXT NOT NULL DEFAULT '',
			outcome TEXT NOT NULL DEFAULT '',
			cost_ms DOUBLE PRECISION,
			state_ms DOUBLE PRECISION,
			queue_ms DOUBLE PRECISION,
			pending_ms DOUBLE PRECISION,
			backlog_ms DOUBLE PRECISION,
			this_req_ms DOUBLE PRECISION,
			health_ms DOUBLE PRECISION,
			ttft_ms DOUBLE PRECISION,
			best_ttft_ms DOUBLE PRECISION,
			effective_queue INTEGER,
			candidate_count INTEGER,
			capacity_rejections INTEGER,
			model_too_large_rejections INTEGER,
			vision_rejections INTEGER,
			ttft_rejections INTEGER,
			effective_tps DOUBLE PRECISION,
			static_tps DOUBLE PRECISION,
			provider_status TEXT,
			provider_trust_level TEXT,
			provider_version TEXT,
			hardware_chip TEXT,
			hardware_chip_family TEXT,
			hardware_tier TEXT,
			memory_gb INTEGER,
			gpu_cores INTEGER,
			cpu_cores INTEGER,
			system_memory_pressure DOUBLE PRECISION,
			system_cpu_usage DOUBLE PRECISION,
			system_thermal_state TEXT,
			gpu_memory_active_gb DOUBLE PRECISION,
			gpu_memory_peak_gb DOUBLE PRECISION,
			gpu_memory_cache_gb DOUBLE PRECISION,
			slot_state TEXT,
			backend_running INTEGER,
			backend_waiting INTEGER,
			active_token_budget_used BIGINT,
			active_token_budget_max BIGINT,
			queued_token_budget BIGINT,
			estimated_prompt_tokens INTEGER,
			requested_max_tokens INTEGER,
			requires_vision BOOLEAN NOT NULL DEFAULT FALSE,
			has_tools BOOLEAN NOT NULL DEFAULT FALSE,
			self_route_only BOOLEAN NOT NULL DEFAULT FALSE,
			prefer_owner BOOLEAN NOT NULL DEFAULT FALSE,
			cache_affinity_key TEXT NOT NULL DEFAULT '',
			final_status TEXT NOT NULL DEFAULT '',
			error_code INTEGER,
			error_class TEXT,
			prompt_tokens INTEGER,
			completion_tokens INTEGER,
			reasoning_tokens INTEGER,
			cost_micro_usd BIGINT,
			actual_ttft_ms DOUBLE PRECISION,
			dispatch_to_first_chunk_ms DOUBLE PRECISION,
			total_duration_ms DOUBLE PRECISION,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			provider_region TEXT,
			consumer_region TEXT,
			parse_ms DOUBLE PRECISION,
			reserve_ms DOUBLE PRECISION,
			route_ms DOUBLE PRECISION,
			encrypt_ms DOUBLE PRECISION,
			queue_wait_ms DOUBLE PRECISION,
			dispatch_ms DOUBLE PRECISION,
			actual_decode_tps DOUBLE PRECISION,
			admitted_but_failed BOOL,
			used_backup BOOL,
			backup_won BOOL,
			error_reason TEXT,
			UNIQUE(request_id, attempt)
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_inference_routes_created ON inference_routes(created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_inference_routes_provider ON inference_routes(provider_id, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_inference_routes_model ON inference_routes(model, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_inference_routes_request ON inference_routes(request_id);
-- +goose StatementEnd
-- +goose StatementBegin
DO $$
		BEGIN
			IF NOT EXISTS (
				SELECT 1
				FROM pg_index i
				JOIN pg_class t ON t.oid = i.indrelid
				WHERE t.oid = 'inference_routes'::regclass
				  AND i.indisunique
				  AND ARRAY(
					SELECT a.attname::text
					FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
					JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
					ORDER BY k.ord
				  ) = ARRAY['request_id', 'attempt']
			) THEN
				CREATE UNIQUE INDEX idx_inference_routes_request_attempt_unique ON inference_routes(request_id, attempt);
			END IF;
		END $$;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS provider_region TEXT;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS consumer_region TEXT;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS parse_ms DOUBLE PRECISION;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS reserve_ms DOUBLE PRECISION;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS route_ms DOUBLE PRECISION;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS encrypt_ms DOUBLE PRECISION;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS queue_wait_ms DOUBLE PRECISION;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS dispatch_ms DOUBLE PRECISION;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS actual_decode_tps DOUBLE PRECISION;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS admitted_but_failed BOOL;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS used_backup BOOL;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS backup_won BOOL;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS error_reason TEXT;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION clear_legacy_cache_affinity_key()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
	NEW.cache_affinity_key := '';
	RETURN NEW;
END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN
	IF NOT EXISTS (
		SELECT 1
		FROM pg_trigger tg
		JOIN pg_class target ON target.oid = tg.tgrelid
		JOIN pg_namespace ns ON ns.oid = target.relnamespace
		WHERE tg.tgname = 'clear_legacy_cache_affinity_key'
		  AND NOT tg.tgisinternal
		  AND target.relname = 'inference_routes'
		  AND ns.nspname = current_schema()
	) THEN
		CREATE TRIGGER clear_legacy_cache_affinity_key
		BEFORE INSERT OR UPDATE OF cache_affinity_key ON inference_routes
		FOR EACH ROW EXECUTE FUNCTION clear_legacy_cache_affinity_key();
	END IF;
END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN
	IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE id = 'scrub_inference_route_cache_affinity_v1') THEN
		IF EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = current_schema()
			  AND table_name = 'inference_routes'
			  AND column_name = 'cache_affinity_key'
		) THEN
			UPDATE inference_routes SET cache_affinity_key = '' WHERE cache_affinity_key <> '';
		END IF;
		INSERT INTO schema_migrations (id) VALUES ('scrub_inference_route_cache_affinity_v1');
	END IF;
END $$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS request_rejections (
			id BIGSERIAL PRIMARY KEY,
			request_id TEXT,
			endpoint TEXT,
			stage TEXT,
			reason_code TEXT,
			http_status INT,
			consumer_key_hash TEXT,
			key_id TEXT,
			client_class TEXT,
			requested_model TEXT,
			resolved_model TEXT,
			stream BOOL,
			n INT,
			estimated_prompt_tokens INT,
			requested_max_tokens INT,
			requires_vision BOOL,
			has_image BOOL,
			has_audio BOOL,
			has_tools BOOL,
			tool_count INT,
			response_format TEXT,
			self_route_only BOOL,
			prefer_owner BOOL,
			params JSONB,
			request_body_bytes INT,
			retry_after_ms INT,
			could_have_served BOOL,
			candidate_count INT,
			capacity_rejections INT,
			model_too_large_rejections INT,
			vision_rejections INT,
			warm_provider_existed BOOL,
			best_ttft_ms DOUBLE PRECISION,
			shortfall_micro_usd BIGINT,
			limit_kind TEXT,
			over_by BIGINT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_rejections_created ON request_rejections(created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_rejections_reason ON request_rejections(reason_code, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_rejections_model ON request_rejections(resolved_model, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_rejections_status ON request_rejections(http_status, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_rejections_servable ON request_rejections(could_have_served, created_at DESC) WHERE could_have_served = true;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS code_attestations (
			se_pubkey TEXT PRIMARY KEY,
			version TEXT NOT NULL DEFAULT '',
			attested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			apns_token TEXT NOT NULL DEFAULT '',
			node_public_key TEXT NOT NULL DEFAULT '',
			binary_hash TEXT NOT NULL DEFAULT ''
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS apns_token TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS node_public_key TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS binary_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS continuous_coverage_until TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS code_attest_push_budgets (
			se_pubkey TEXT NOT NULL,
			token_hash TEXT NOT NULL DEFAULT '',
			next_push_at TIMESTAMPTZ NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (se_pubkey, token_hash)
		);
-- +goose StatementEnd
-- +goose StatementBegin
DO $$
		DECLARE key_columns TEXT[];
		BEGIN
			SELECT array_agg(a.attname::TEXT ORDER BY k.ordinality)
			  INTO key_columns
			  FROM pg_constraint c
			  CROSS JOIN LATERAL unnest(c.conkey)
			    WITH ORDINALITY AS k(attnum, ordinality)
			  JOIN pg_attribute a
			    ON a.attrelid = c.conrelid AND a.attnum = k.attnum
			 WHERE c.conrelid = 'code_attest_push_budgets'::regclass
			   AND c.contype = 'p';
			IF key_columns IS DISTINCT FROM
			   ARRAY['se_pubkey', 'token_hash']::TEXT[] THEN
				ALTER TABLE code_attest_push_budgets
					DROP CONSTRAINT IF EXISTS code_attest_push_budgets_pkey;
				ALTER TABLE code_attest_push_budgets
					ADD CONSTRAINT code_attest_push_budgets_pkey
					PRIMARY KEY (se_pubkey, token_hash);
			END IF;
		END $$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_code_attest_push_budgets_due
			ON code_attest_push_budgets(next_push_at);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE code_attest_push_budgets
			ADD COLUMN IF NOT EXISTS last_clear_at TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_trust_reuse (
			se_pubkey TEXT PRIMARY KEY,
			serial TEXT NOT NULL DEFAULT '',
			trust_level TEXT NOT NULL DEFAULT '',
			binary_hash TEXT NOT NULL DEFAULT '',
			sip_enabled BOOL NOT NULL DEFAULT FALSE,
			secure_boot_full BOOL NOT NULL DEFAULT FALSE,
			mda_udid TEXT NOT NULL DEFAULT '',
			verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_verified_binary_hash TEXT NOT NULL DEFAULT '',
			hardware_proof_verified_at TIMESTAMPTZ,
			application_proof_verified_at TIMESTAMPTZ,
			evidence_generation BIGINT NOT NULL DEFAULT 1,
			revocation_generation BIGINT NOT NULL DEFAULT 0,
			revocation_event_id TEXT NOT NULL DEFAULT '',
			revoked_at TIMESTAMPTZ
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS last_verified_binary_hash TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS hardware_proof_verified_at TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS application_proof_verified_at TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS evidence_generation BIGINT NOT NULL DEFAULT 1;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS revocation_generation BIGINT NOT NULL DEFAULT 0;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS revocation_event_id TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS continuous_coverage_until TIMESTAMPTZ;
-- +goose StatementEnd
-- +goose StatementBegin
UPDATE provider_trust_reuse
		 SET hardware_proof_verified_at = verified_at
		 WHERE hardware_proof_verified_at IS NULL;
-- +goose StatementEnd
-- +goose StatementBegin
UPDATE provider_trust_reuse
		 SET last_verified_binary_hash = binary_hash
		 WHERE last_verified_binary_hash = '' AND binary_hash <> '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ALTER COLUMN hardware_proof_verified_at SET DEFAULT NOW();
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_trust_reuse ALTER COLUMN hardware_proof_verified_at SET NOT NULL;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_verification_jobs (
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
		);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_verification_jobs
		 ADD COLUMN IF NOT EXISTS reopen_pending BOOLEAN NOT NULL DEFAULT FALSE;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_verification_jobs_due
		 ON provider_verification_jobs(priority, next_attempt_at)
		 WHERE task_state IN ('pending', 'backoff');
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_verification_jobs_claim
		 ON provider_verification_jobs(claim_expires_at)
		 WHERE claim_owner <> '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE provider_sessions ADD COLUMN IF NOT EXISTS provider_key TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_provider_sessions_key ON provider_sessions(provider_key, connected_at) WHERE provider_key <> '';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS provider_floor_draws (
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
		);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_floor_draws_epoch ON provider_floor_draws(epoch_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_floor_draws_account ON provider_floor_draws(account_id, epoch_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_demand_requests (
 id BIGSERIAL UNIQUE,
 coord_request_id TEXT PRIMARY KEY,
 received_at TIMESTAMPTZ NOT NULL,
 model TEXT NOT NULL,
 consumer_hash TEXT NOT NULL,
 outcome TEXT NOT NULL,
 http_status INTEGER NOT NULL,
 revision BIGINT NOT NULL,
 evidence_conflict BOOLEAN NOT NULL DEFAULT FALSE
);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_demand_hourly (
 hour TIMESTAMPTZ NOT NULL,
 model TEXT NOT NULL,
 consumer_hash TEXT NOT NULL,
 requests BIGINT NOT NULL,
 completed BIGINT NOT NULL,
 capacity_rejected BIGINT NOT NULL,
 latency_rejected BIGINT NOT NULL,
 timed_out BIGINT NOT NULL,
 failed BIGINT NOT NULL,
 cancelled BIGINT NOT NULL,
 unknown BIGINT NOT NULL,
 excluded BIGINT NOT NULL,
 http_429 BIGINT NOT NULL,
 PRIMARY KEY(hour,model,consumer_hash)
);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION update_model_demand_hourly() RETURNS trigger AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.outcome=NEW.outcome AND (OLD.http_status=429)=(NEW.http_status=429) THEN RETURN NEW; END IF;
 INSERT INTO model_demand_hourly (hour,model,consumer_hash,requests,completed,capacity_rejected,latency_rejected,timed_out,failed,cancelled,unknown,excluded,http_429)
 VALUES (date_trunc('hour',NEW.received_at,'UTC'),NEW.model,NEW.consumer_hash,
 1-CASE WHEN TG_OP='UPDATE' THEN 1 ELSE 0 END,
 (NEW.outcome='completed')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='completed')::integer ELSE 0 END,
 (NEW.outcome='capacity_rejected')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='capacity_rejected')::integer ELSE 0 END,
 (NEW.outcome='latency_rejected')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='latency_rejected')::integer ELSE 0 END,
 (NEW.outcome='timed_out')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='timed_out')::integer ELSE 0 END,
 (NEW.outcome='failed')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='failed')::integer ELSE 0 END,
 (NEW.outcome='cancelled')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='cancelled')::integer ELSE 0 END,
 (NEW.outcome='unknown')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='unknown')::integer ELSE 0 END,
 (NEW.outcome='excluded')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.outcome='excluded')::integer ELSE 0 END,
 (NEW.http_status=429 AND NEW.outcome<>'excluded')::integer-CASE WHEN TG_OP='UPDATE' THEN (OLD.http_status=429 AND OLD.outcome<>'excluded')::integer ELSE 0 END)
 ON CONFLICT (hour,model,consumer_hash) DO UPDATE SET
 requests=model_demand_hourly.requests+EXCLUDED.requests,
 completed=model_demand_hourly.completed+EXCLUDED.completed,
 capacity_rejected=model_demand_hourly.capacity_rejected+EXCLUDED.capacity_rejected,
 latency_rejected=model_demand_hourly.latency_rejected+EXCLUDED.latency_rejected,
 timed_out=model_demand_hourly.timed_out+EXCLUDED.timed_out,
 failed=model_demand_hourly.failed+EXCLUDED.failed,
 cancelled=model_demand_hourly.cancelled+EXCLUDED.cancelled,
 unknown=model_demand_hourly.unknown+EXCLUDED.unknown,
 excluded=model_demand_hourly.excluded+EXCLUDED.excluded,
 http_429=model_demand_hourly.http_429+EXCLUDED.http_429;
 RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE OR REPLACE TRIGGER model_demand_rollup
 AFTER INSERT OR UPDATE ON model_demand_requests FOR EACH ROW EXECUTE FUNCTION update_model_demand_hourly();
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_model_demand_received ON model_demand_requests (received_at);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS model_demand_collection (singleton BOOLEAN PRIMARY KEY CHECK(singleton), started_at TIMESTAMPTZ NOT NULL);
-- +goose StatementEnd
-- +goose StatementBegin
INSERT INTO model_demand_collection (singleton,started_at) VALUES (TRUE,NOW()) ON CONFLICT DO NOTHING;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS request_outcomes (
 id BIGSERIAL UNIQUE,
 coord_request_id TEXT PRIMARY KEY CHECK (coord_request_id <> ''),
 received_at TIMESTAMPTZ NOT NULL,
 updated_at TIMESTAMPTZ NOT NULL,
 revision BIGINT NOT NULL,
 evidence_conflict BOOLEAN NOT NULL DEFAULT FALSE,
 record JSONB NOT NULL
);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_outcomes_received ON request_outcomes (received_at, coord_request_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS request_profiles (
			id BIGSERIAL PRIMARY KEY,
			coord_request_id TEXT NOT NULL,
			request_id TEXT NOT NULL,
			attempt INT NOT NULL,
			backup_of TEXT NOT NULL DEFAULT '',
			winning BOOL NOT NULL DEFAULT FALSE,
			endpoint TEXT NOT NULL DEFAULT '',
			stream BOOL NOT NULL DEFAULT FALSE,
			model TEXT NOT NULL DEFAULT '',
			public_model TEXT NOT NULL DEFAULT '',
			provider_id TEXT NOT NULL DEFAULT '',
			provider_version TEXT NOT NULL DEFAULT '',
			chip_family TEXT NOT NULL DEFAULT '',
			kv_backend TEXT NOT NULL DEFAULT '',
			final_status TEXT NOT NULL DEFAULT '',
			error_reason TEXT NOT NULL DEFAULT '',
			terminal_cause TEXT NOT NULL DEFAULT '',
			client_outcome TEXT NOT NULL DEFAULT '',
			provider_outcome TEXT NOT NULL DEFAULT '',
			client_gone_phase TEXT NOT NULL DEFAULT '',
			first_content_budget_ms INT NOT NULL DEFAULT 0,
			admission_mode TEXT NOT NULL DEFAULT '',
			predictive_bypass TEXT NOT NULL DEFAULT '',
			reservation_ttft_ceiling_ms DOUBLE PRECISION,
			dispatch_budget_ms BIGINT,
			estimated_prompt_tokens INT NOT NULL DEFAULT 0,
			requested_max_tokens INT NOT NULL DEFAULT 0,
			requires_vision BOOL NOT NULL DEFAULT FALSE,
			has_tools BOOL NOT NULL DEFAULT FALSE,
			received_at TIMESTAMPTZ NOT NULL,

			auth_done_us BIGINT,
			ratelimit_done_us BIGINT,
			sealed_open_us BIGINT,
			handler_entry_us BIGINT,
			parsed_us BIGINT,
			reserved_us BIGINT,
			media_fetched_us BIGINT,
			preflight_done_us BIGINT,
			plan_done_us BIGINT,
			attempt_start_us BIGINT,
			reserve_lock_acquired_us BIGINT,
			reserve_done_us BIGINT,
			queued_us BIGINT,
			dequeued_us BIGINT,
			topup_done_us BIGINT,
			encrypted_us BIGINT,
			write_submitted_us BIGINT,
			write_dequeued_us BIGINT,
			write_done_us BIGINT,
			accepted_us BIGINT,
			first_chunk_ingress_us BIGINT,
			first_chunk_dequeued_us BIGINT,
			first_content_ingress_us BIGINT,
			first_content_us BIGINT,
			headers_written_us BIGINT,
			first_flush_us BIGINT,
			last_flush_us BIGINT,
			client_gone_us BIGINT,
			cancel_sent_us BIGINT,
			complete_ingress_us BIGINT,
			done_flushed_us BIGINT,
			finalized_us BIGINT,
			settle_db_us BIGINT,
			db_us BIGINT,
			db_calls INT NOT NULL DEFAULT 0,

			body_bytes INT NOT NULL DEFAULT 0,
			sealed_body_bytes INT NOT NULL DEFAULT 0,
			auth_kind TEXT NOT NULL DEFAULT '',
			auth_db_read BOOL NOT NULL DEFAULT FALSE,
			reserve_mode TEXT NOT NULL DEFAULT '',
			media_items INT NOT NULL DEFAULT 0,
			media_bytes BIGINT NOT NULL DEFAULT 0,
			preflight_outcome TEXT NOT NULL DEFAULT '',
			plan_outcome TEXT NOT NULL DEFAULT '',
			chunks_in INT NOT NULL DEFAULT 0,
			chunks_out INT NOT NULL DEFAULT 0,
			bytes_out BIGINT NOT NULL DEFAULT 0,
			decrypt_us_total BIGINT NOT NULL DEFAULT 0,
			max_chunk_gap_us BIGINT NOT NULL DEFAULT 0,
			held_preamble_chunks INT NOT NULL DEFAULT 0,
			client_write_err BOOL NOT NULL DEFAULT FALSE,
			attempts_total INT NOT NULL DEFAULT 0,
			failed_attempts INT NOT NULL DEFAULT 0,
			failed_attempts_us BIGINT NOT NULL DEFAULT 0,
			backup_launched BOOL NOT NULL DEFAULT FALSE,
			backup_won BOOL NOT NULL DEFAULT FALSE,
			transport_est_us BIGINT,
			slept_us BIGINT,
			timing_anomaly BOOL NOT NULL DEFAULT FALSE,

			candidate_set_size INT NOT NULL DEFAULT 0,
			scanned INT NOT NULL DEFAULT 0,
			gate_rejections JSONB,
			runner_up_provider_id TEXT NOT NULL DEFAULT '',
			runner_up_cost_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			near_tie_pool_size INT NOT NULL DEFAULT 0,
			selection_path TEXT NOT NULL DEFAULT '',
			best_idle_provider_id TEXT NOT NULL DEFAULT '',
			best_idle_ttft_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			predicted_ttft_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			raw_ttft_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			predicted_decode_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			snapshot_age_ms INT NOT NULL DEFAULT 0,
			pending_for_model INT NOT NULL DEFAULT 0,
			total_pending INT NOT NULL DEFAULT 0,
			capacity_rate_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			cache_discount_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
			shadow_would_shed BOOL,
			shadow_idle_alternative BOOL,
			lock_wait_us BIGINT NOT NULL DEFAULT 0,
			scan_us BIGINT NOT NULL DEFAULT 0,
			admit_us BIGINT NOT NULL DEFAULT 0,
			preflight_us BIGINT NOT NULL DEFAULT 0,
			ttft_calibration_ratio DOUBLE PRECISION NOT NULL DEFAULT 0,
			prefill_decode_ratio DOUBLE PRECISION NOT NULL DEFAULT 0,
			queue_position_at_enqueue INT NOT NULL DEFAULT 0,
			queue_depth_at_enqueue INT NOT NULL DEFAULT 0,
			drain_trigger TEXT NOT NULL DEFAULT '',
			candidates JSONB,

			prov_total_us BIGINT,
			prov_first_delta_us BIGINT,
			prov_engine_submit_us BIGINT,
			prov_engine_admitted_us BIGINT,
			prov_prompt_prep_us BIGINT,
			prov_load_wait_us BIGINT,
			prov_load_cold BOOL,
			prov_running_at_admit INT,
			prov_waiting_at_admit INT,
			prov_kv_bytes_in_use_at_admit BIGINT,
			prov_cancel_stage TEXT NOT NULL DEFAULT '',
			eng_queue_wait_ns BIGINT,
			eng_first_token_ns BIGINT,
			eng_prompt_computed_ns BIGINT,
			eng_prefill_chunks INT,
			eng_decode_steps INT,
			eng_mtp_accepted INT,
			eng_finish_reason TEXT NOT NULL DEFAULT '',
			provider_profile JSONB,
			provider_profile_valid BOOL NOT NULL DEFAULT FALSE,
			provider_profile_invalid_reason TEXT NOT NULL DEFAULT '',
			provider_profile_consistent BOOL,

			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			UNIQUE (request_id, attempt)
		) WITH (autovacuum_vacuum_scale_factor=0.02, autovacuum_analyze_scale_factor=0.01);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_profiles_created ON request_profiles(created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_profiles_coord ON request_profiles(coord_request_id);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_request_profiles_provider ON request_profiles(provider_id, created_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS fleet_snapshots (
			id BIGSERIAL PRIMARY KEY,
			sampled_at TIMESTAMPTZ NOT NULL,
			provider_id TEXT NOT NULL,
			model TEXT NOT NULL DEFAULT '',
			eligibility_reason TEXT NOT NULL DEFAULT '',
			slot_state TEXT NOT NULL DEFAULT '',
			num_running INT NOT NULL DEFAULT 0,
			num_waiting INT NOT NULL DEFAULT 0,
			queued_prefill_tokens INT NOT NULL DEFAULT 0,
			partial_prefill_rows INT NOT NULL DEFAULT 0,
			active_token_budget_used BIGINT NOT NULL DEFAULT 0,
			active_token_budget_max BIGINT NOT NULL DEFAULT 0,
			kv_bytes_in_use BIGINT NOT NULL DEFAULT 0,
			kv_bytes_capacity BIGINT NOT NULL DEFAULT 0,
			observed_decode_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			observed_prefill_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			isolated_prefill_tps DOUBLE PRECISION NOT NULL DEFAULT 0,
			ewma_initialized BOOL,
			max_concurrency INT NOT NULL DEFAULT 0,
			pending_count INT NOT NULL DEFAULT 0,
			effective_cap INT NOT NULL DEFAULT 0,
			cooldown_active BOOL NOT NULL DEFAULT FALSE,
			breaker_open BOOL NOT NULL DEFAULT FALSE,
			clamp_active BOOL NOT NULL DEFAULT FALSE,
			ejected BOOL NOT NULL DEFAULT FALSE,
			gpu_memory_active_gb DOUBLE PRECISION NOT NULL DEFAULT 0,
			gpu_memory_peak_gb DOUBLE PRECISION NOT NULL DEFAULT 0,
			free_for_load_gb DOUBLE PRECISION,
			memory_pressure DOUBLE PRECISION NOT NULL DEFAULT 0,
			cpu_usage DOUBLE PRECISION NOT NULL DEFAULT 0,
			thermal_state TEXT NOT NULL DEFAULT '',
			low_power_mode BOOL,
			memory_pressure_level TEXT NOT NULL DEFAULT '',
			steps_executed BIGINT NOT NULL DEFAULT 0,
			step_wall_ns_total BIGINT NOT NULL DEFAULT 0,
			decode_rows_total BIGINT NOT NULL DEFAULT 0,
			prefill_tokens_total BIGINT NOT NULL DEFAULT 0,
			mtp_rounds_total BIGINT NOT NULL DEFAULT 0,
			mtp_proposed_total BIGINT NOT NULL DEFAULT 0,
			mtp_accepted_total BIGINT NOT NULL DEFAULT 0,
			heartbeat_age_ms INT NOT NULL DEFAULT 0,
			wedge_suspected BOOL NOT NULL DEFAULT FALSE,
			eval_in_flight_ms BIGINT NOT NULL DEFAULT 0,
			requests_served BIGINT NOT NULL DEFAULT 0,
			tokens_generated BIGINT NOT NULL DEFAULT 0,
			cancellations_received BIGINT NOT NULL DEFAULT 0,
			cancellations_before_output BIGINT NOT NULL DEFAULT 0,
			cancellations_partial_complete BIGINT NOT NULL DEFAULT 0,
			generation_errors_after_output BIGINT NOT NULL DEFAULT 0,
			chunk_encryption_errors BIGINT NOT NULL DEFAULT 0,
			stream_closed_without_terminal BIGINT NOT NULL DEFAULT 0,
			cancel_during_model_load BIGINT NOT NULL DEFAULT 0,
			usage_gaps BIGINT NOT NULL DEFAULT 0,
			cancel_stage_pre_accept_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_pre_engine_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_prefill_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_decode_total BIGINT NOT NULL DEFAULT 0,
			cancel_stage_post_terminal_total BIGINT NOT NULL DEFAULT 0,
			tokens_after_cancel_total BIGINT NOT NULL DEFAULT 0,
			cancel_abort_ns_sum BIGINT NOT NULL DEFAULT 0,
			queue_depth_total INT NOT NULL DEFAULT 0,
			queue_depth_by_model JSONB,
			inflight_requests INT NOT NULL DEFAULT 0,
			reserve_lock_wait_p95_us BIGINT NOT NULL DEFAULT 0,
			profile_sink_depth INT NOT NULL DEFAULT 0,
			profile_sink_dropped_total BIGINT NOT NULL DEFAULT 0,
			route_sink_dropped_total BIGINT NOT NULL DEFAULT 0,
			unknown_request_frames_total BIGINT NOT NULL DEFAULT 0,
			goroutines INT NOT NULL DEFAULT 0,
			provider_version TEXT NOT NULL DEFAULT '',
			model_vision BOOL NOT NULL DEFAULT FALSE,
			template_render_ok BOOL
		) WITH (autovacuum_vacuum_scale_factor=0.02, autovacuum_analyze_scale_factor=0.01);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_fleet_snapshots_sampled ON fleet_snapshots(sampled_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS estimated_prompt_tokens INT NOT NULL DEFAULT 0; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS requested_max_tokens INT NOT NULL DEFAULT 0; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS requires_vision BOOL NOT NULL DEFAULT FALSE; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS has_tools BOOL NOT NULL DEFAULT FALSE; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS predictive_bypass TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS reservation_ttft_ceiling_ms DOUBLE PRECISION; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE request_profiles ADD COLUMN IF NOT EXISTS dispatch_budget_ms BIGINT; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE fleet_snapshots ADD COLUMN IF NOT EXISTS provider_version TEXT NOT NULL DEFAULT ''; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE fleet_snapshots ALTER COLUMN free_for_load_gb DROP NOT NULL;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE fleet_snapshots ADD COLUMN IF NOT EXISTS model_vision BOOL NOT NULL DEFAULT FALSE; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
DO $$ BEGIN ALTER TABLE fleet_snapshots ADD COLUMN IF NOT EXISTS template_render_ok BOOL; EXCEPTION WHEN duplicate_column THEN NULL; END $$;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_fleet_snapshots_provider ON fleet_snapshots(provider_id, sampled_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS autopilot_events (
 command_id TEXT NOT NULL, phase TEXT NOT NULL, at TIMESTAMPTZ NOT NULL,
 record JSONB NOT NULL, PRIMARY KEY(command_id,phase)
); CREATE INDEX IF NOT EXISTS autopilot_events_at ON autopilot_events(at);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS app_attest_shadow_keys (
	key_id TEXT PRIMARY KEY, owner TEXT NOT NULL, evidence JSONB NOT NULL,
	counter BIGINT NOT NULL DEFAULT 0 CHECK (counter >= 0 AND counter <= 4294967295),
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- +goose StatementEnd
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS darkbloom_machines (
 id TEXT PRIMARY KEY, assurance TEXT NOT NULL, merged_into TEXT REFERENCES darkbloom_machines(id),
 first_seen TIMESTAMPTZ NOT NULL, last_seen TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS darkbloom_machines_merged_into ON darkbloom_machines(merged_into) WHERE merged_into IS NOT NULL;
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
CREATE INDEX IF NOT EXISTS darkbloom_machine_sessions_open ON darkbloom_machine_sessions(last_seen,session_id) WHERE disconnected_at IS NULL;
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
-- +goose StatementEnd
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS app_attest_evidence (
 id TEXT PRIMARY KEY, session_id TEXT NOT NULL, key_id TEXT NOT NULL, received_at TIMESTAMPTZ NOT NULL,
 action TEXT NOT NULL, sha256 TEXT NOT NULL, context JSONB NOT NULL,
 outcome TEXT NOT NULL DEFAULT 'pending', details JSONB NOT NULL DEFAULT '{}', completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS app_attest_evidence_session ON app_attest_evidence(session_id,received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_evidence_key ON app_attest_evidence(key_id,received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_evidence_time ON app_attest_evidence(received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_evidence_pending ON app_attest_evidence(received_at) WHERE outcome='pending';
CREATE TABLE IF NOT EXISTS app_attest_evidence_blobs (
 evidence_id TEXT PRIMARY KEY REFERENCES app_attest_evidence(id),
 proof_field TEXT NOT NULL, proof BYTEA NOT NULL
);
REVOKE ALL ON app_attest_evidence_blobs FROM PUBLIC;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS app_attest_enrollments (id TEXT PRIMARY KEY,owner TEXT NOT NULL,key_id TEXT NOT NULL,created_at TIMESTAMPTZ NOT NULL,context JSONB NOT NULL);
-- +goose StatementEnd
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS app_attest_receipts (
 id TEXT PRIMARY KEY,key_id TEXT NOT NULL,evidence_id TEXT NOT NULL,parent_id TEXT NOT NULL,
 received_at TIMESTAMPTZ NOT NULL,outcome TEXT NOT NULL,http_status INTEGER NOT NULL,
 details JSONB NOT NULL,context JSONB NOT NULL,next_at TIMESTAMPTZ NOT NULL,expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS app_attest_receipts_key ON app_attest_receipts(key_id,received_at DESC);
CREATE INDEX IF NOT EXISTS app_attest_receipts_recovery ON app_attest_receipts(key_id,received_at DESC) WHERE outcome='receipt_creation_time';
CREATE TABLE IF NOT EXISTS app_attest_receipt_blobs (
 receipt_id TEXT PRIMARY KEY REFERENCES app_attest_receipts(id),body BYTEA NOT NULL,response_body BYTEA NOT NULL
);
REVOKE ALL ON app_attest_receipt_blobs FROM PUBLIC;
CREATE TABLE IF NOT EXISTS app_attest_receipt_jobs (
 key_id TEXT PRIMARY KEY,receipt_id TEXT NOT NULL REFERENCES app_attest_receipts(id),next_at TIMESTAMPTZ NOT NULL,
 lease_until TIMESTAMPTZ,attempts BIGINT NOT NULL DEFAULT 0
);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS app_attest_key_revocations (
 key_id TEXT PRIMARY KEY REFERENCES app_attest_shadow_keys(key_id),
 account_id TEXT NOT NULL, reason TEXT NOT NULL, revoked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS app_attest_build_qualifications (
 binary_hash TEXT PRIMARY KEY CHECK (binary_hash ~ '^[0-9a-f]{64}$'),
 record JSONB NOT NULL
);
-- +goose StatementEnd
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS app_attest_key_rotations (
 key_id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, account_id TEXT NOT NULL,
 requested_at TIMESTAMPTZ NOT NULL, failures INTEGER NOT NULL, reason TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS app_attest_key_rotations_machine ON app_attest_key_rotations(machine_id,requested_at DESC);
-- +goose StatementEnd
-- +goose StatementBegin

CREATE TABLE IF NOT EXISTS model_token_promotions (
 model_id TEXT PRIMARY KEY,
 tokens BIGINT NOT NULL CHECK (tokens > 0 AND tokens <= 1000000000000),
 claim_starts_at TIMESTAMPTZ NOT NULL,
 claim_ends_at TIMESTAMPTZ CHECK (claim_ends_at > claim_starts_at),
 signup_cutoff_at TIMESTAMPTZ NOT NULL,
 max_claims BIGINT NOT NULL CHECK (max_claims>0 AND max_claims<=1000000),
 claimed_count BIGINT NOT NULL DEFAULT 0 CHECK (claimed_count>=0 AND claimed_count<=max_claims),
 enabled BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE IF NOT EXISTS model_token_grants (
 account_id TEXT NOT NULL REFERENCES users(account_id),
 model_id TEXT NOT NULL REFERENCES model_token_promotions(model_id),
 total_tokens BIGINT NOT NULL CHECK (total_tokens > 0),
 used_tokens BIGINT NOT NULL DEFAULT 0 CHECK (used_tokens >= 0),
 reserved_tokens BIGINT NOT NULL DEFAULT 0 CHECK (reserved_tokens >= 0),
 claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 PRIMARY KEY (account_id, model_id),
 CHECK (used_tokens + reserved_tokens <= total_tokens)
);
CREATE TABLE IF NOT EXISTS model_token_provider_carries (
 account_id TEXT PRIMARY KEY,
 remainder BIGINT NOT NULL DEFAULT 0 CHECK (remainder >= 0 AND remainder < 100000000)
);
CREATE TABLE IF NOT EXISTS model_token_reservations (
 id TEXT PRIMARY KEY,
 account_id TEXT NOT NULL,
 model_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK (state IN ('reserved','settled','released')),
 record JSONB NOT NULL,
 created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 touched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
 FOREIGN KEY (account_id, model_id) REFERENCES model_token_grants(account_id, model_id)
);
ALTER TABLE model_token_reservations ADD COLUMN IF NOT EXISTS touched_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
CREATE INDEX IF NOT EXISTS idx_model_token_reservations_open ON model_token_reservations(touched_at) WHERE state = 'reserved';
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS cache_routing_holders (
 key TEXT NOT NULL,
 cache_epoch TEXT NOT NULL,
 tier TEXT NOT NULL DEFAULT '',
 model_id TEXT NOT NULL,
 model_aggregate_hash TEXT NOT NULL DEFAULT '',
 prompt_contract_id TEXT NOT NULL DEFAULT '',
 block_hash_version TEXT NOT NULL DEFAULT '',
 ready_boundary_mode TEXT NOT NULL DEFAULT '',
 anchor_token_count INTEGER NOT NULL DEFAULT 0,
 required_recompute_tokens INTEGER NOT NULL DEFAULT 0,
 stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 measured_stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 measured_expires_at TIMESTAMPTZ,
 updated_at TIMESTAMPTZ NOT NULL,
 expires_at TIMESTAMPTZ NOT NULL,
 PRIMARY KEY (key, cache_epoch)
);
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE cache_routing_holders
 ADD COLUMN IF NOT EXISTS measured_stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS measured_expires_at TIMESTAMPTZ,
 ADD COLUMN IF NOT EXISTS ready_boundary_mode TEXT NOT NULL DEFAULT '';
-- +goose StatementEnd
-- +goose StatementBegin
ALTER TABLE cache_routing_holders DROP COLUMN IF EXISTS anchor_chain_hash;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_cache_routing_holders_expires ON cache_routing_holders(expires_at);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_cache_routing_holders_updated ON cache_routing_holders(updated_at);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS cache_routing_demand (
 key TEXT PRIMARY KEY,
 seen_at TIMESTAMPTZ NOT NULL
);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE INDEX IF NOT EXISTS idx_cache_routing_demand_seen ON cache_routing_demand(seen_at);
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TABLE IF NOT EXISTS cache_routing_meta (
 name TEXT PRIMARY KEY,
 value TEXT NOT NULL,
 updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- +goose StatementEnd
