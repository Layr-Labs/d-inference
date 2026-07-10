-- Darkbloom schema baseline extracted from the legacy serving-startup migration.
-- This migration is intentionally idempotent so it can initialize a fresh database
-- and adopt a database maintained by the pre-versioned coordinator.
-- darkbloom:transaction=false
-- darkbloom:bootstrap=true

CREATE TABLE IF NOT EXISTS schema_migration_versions (
    version BIGINT PRIMARY KEY CHECK (version > 0),
    name TEXT NOT NULL,
    checksum TEXT NOT NULL CHECK (length(checksum) = 64),
    transactional BOOLEAN NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS schema_migrations (
			id TEXT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE TABLE IF NOT EXISTS coordinator_ownership (
			singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
			epoch BIGINT NOT NULL,
			owner_id TEXT NOT NULL,
			acquired_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

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

ALTER TABLE providers ADD COLUMN IF NOT EXISTS location JSONB;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS trust_level TEXT NOT NULL DEFAULT 'none';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS attested BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS attestation_result JSONB;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS se_public_key TEXT NOT NULL DEFAULT '';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS public_key TEXT NOT NULL DEFAULT '';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS serial_number TEXT NOT NULL DEFAULT '';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS mda_verified BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS mda_cert_chain JSONB;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS version TEXT NOT NULL DEFAULT '';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS runtime_verified BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS python_hash TEXT NOT NULL DEFAULT '';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS runtime_hash TEXT NOT NULL DEFAULT '';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_challenge_verified TIMESTAMPTZ;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS failed_challenges INT NOT NULL DEFAULT 0;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS account_id TEXT NOT NULL DEFAULT '';

ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_requests_served BIGINT NOT NULL DEFAULT 0;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_tokens_generated BIGINT NOT NULL DEFAULT 0;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_requests_served BIGINT NOT NULL DEFAULT 0;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_tokens_generated BIGINT NOT NULL DEFAULT 0;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS lifetime_stats JSONB NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE providers ADD COLUMN IF NOT EXISTS last_session_stats JSONB NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_providers_serial ON providers(serial_number) WHERE serial_number != '';

CREATE INDEX IF NOT EXISTS idx_providers_account ON providers(account_id, last_seen DESC) WHERE account_id != '';

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

CREATE TABLE IF NOT EXISTS api_keys (
			key_hash TEXT PRIMARY KEY,
			raw_prefix TEXT NOT NULL,
			owner_account_id TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			active BOOLEAN NOT NULL DEFAULT TRUE
		);

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS owner_account_id TEXT NOT NULL DEFAULT '';

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS id TEXT NOT NULL DEFAULT '';

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '';

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_micro_usd BIGINT;

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS limit_reset TEXT NOT NULL DEFAULT 'none';

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS rpm_limit BIGINT;

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS itpm_limit BIGINT;

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS otpm_limit BIGINT;

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS allowed_models TEXT NOT NULL DEFAULT '';

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ;

ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS self_route_only BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE api_keys SET id = 'key_' || substr(md5(key_hash), 1, 24) WHERE id IS NULL OR id = '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_api_keys_id ON api_keys(id) WHERE id <> '';

CREATE INDEX IF NOT EXISTS idx_api_keys_owner ON api_keys(owner_account_id) WHERE owner_account_id <> '';

CREATE TABLE IF NOT EXISTS usage (
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
		);

ALTER TABLE usage ADD COLUMN IF NOT EXISTS request_id TEXT NOT NULL DEFAULT '';

ALTER TABLE usage ADD COLUMN IF NOT EXISTS cost_micro_usd BIGINT NOT NULL DEFAULT 0;

ALTER TABLE usage ADD COLUMN IF NOT EXISTS request_location JSONB;

ALTER TABLE usage ADD COLUMN IF NOT EXISTS key_id TEXT NOT NULL DEFAULT '';

ALTER TABLE usage ADD COLUMN IF NOT EXISTS public_model TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_usage_created ON usage(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_usage_consumer ON usage(consumer_key_hash, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_usage_provider ON usage(provider_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_usage_key ON usage(key_id, created_at DESC) WHERE key_id <> '';

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

CREATE TABLE IF NOT EXISTS balances (
			account_id TEXT PRIMARY KEY,
			balance_micro_usd BIGINT NOT NULL DEFAULT 0,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE TABLE IF NOT EXISTS ledger_entries (
			id BIGSERIAL PRIMARY KEY,
			account_id TEXT NOT NULL,
			entry_type TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			balance_after BIGINT NOT NULL,
			reference TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_ledger_account ON ledger_entries(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS balance_reservation_operations (
			operation_key TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			kind TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			withdrawable_micro_usd BIGINT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			CHECK (kind IN ('reserve', 'release')),
			CHECK (amount_micro_usd >= 0),
			CHECK (withdrawable_micro_usd >= 0 AND withdrawable_micro_usd <= amount_micro_usd)
		);

CREATE INDEX IF NOT EXISTS idx_balance_reservation_operations_account ON balance_reservation_operations(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS inference_settlements (
			reservation_id TEXT PRIMARY KEY,
			request_id TEXT NOT NULL,
			consumer_account_id TEXT NOT NULL,
			reserved_micro_usd BIGINT NOT NULL,
			reserved_withdrawable_micro_usd BIGINT NOT NULL,
			reservation_pre_debited BOOLEAN NOT NULL,
			cost_micro_usd BIGINT NOT NULL,
			provider_account_id TEXT NOT NULL DEFAULT '',
			provider_id TEXT NOT NULL DEFAULT '',
			provider_key TEXT NOT NULL DEFAULT '',
			provider_payout_micro_usd BIGINT NOT NULL DEFAULT 0,
			platform_fee_micro_usd BIGINT NOT NULL DEFAULT 0,
			referrer_account_id TEXT NOT NULL DEFAULT '',
			referral_reward_micro_usd BIGINT NOT NULL DEFAULT 0,
			model TEXT NOT NULL,
			public_model TEXT NOT NULL DEFAULT '',
			key_id TEXT NOT NULL DEFAULT '',
			prompt_tokens INTEGER NOT NULL,
			completion_tokens INTEGER NOT NULL,
			record_usage BOOLEAN NOT NULL,
			request_location JSONB,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

ALTER TABLE inference_settlements ADD COLUMN IF NOT EXISTS reservation_pre_debited BOOLEAN NOT NULL DEFAULT TRUE;

CREATE UNIQUE INDEX IF NOT EXISTS idx_inference_settlements_request ON inference_settlements(request_id);

CREATE TABLE IF NOT EXISTS inference_settlement_reviews (
			reservation_id TEXT PRIMARY KEY,
			request_id TEXT NOT NULL,
			reason TEXT NOT NULL,
			payload JSONB NOT NULL,
			status TEXT NOT NULL DEFAULT 'review_pending',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE TABLE IF NOT EXISTS inference_completion_intents (
			reservation_id TEXT PRIMARY KEY,
			request_id TEXT NOT NULL,
			provider_id TEXT NOT NULL,
			prompt_tokens BIGINT NOT NULL,
			completion_tokens BIGINT NOT NULL,
			reasoning_tokens BIGINT NOT NULL,
			received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_ledger_reward ON ledger_entries(account_id, created_at DESC) WHERE entry_type IN ('referral_reward','admin_reward');

CREATE TABLE IF NOT EXISTS referrers (
			account_id TEXT PRIMARY KEY,
			code TEXT UNIQUE NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_referrers_code ON referrers(code);

CREATE TABLE IF NOT EXISTS referrals (
			referred_account TEXT PRIMARY KEY,
			referrer_code TEXT NOT NULL REFERENCES referrers(code),
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_referrals_code ON referrals(referrer_code);

CREATE TABLE IF NOT EXISTS billing_sessions (
			id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			payment_method TEXT NOT NULL,
			currency TEXT NOT NULL DEFAULT 'usd',
			amount_micro_usd BIGINT NOT NULL,
			external_id TEXT NOT NULL DEFAULT '',
			processed_event_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			referral_code TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			completed_at TIMESTAMPTZ
		);

CREATE INDEX IF NOT EXISTS idx_billing_sessions_account ON billing_sessions(account_id);

CREATE INDEX IF NOT EXISTS idx_billing_sessions_external ON billing_sessions(external_id);

ALTER TABLE billing_sessions ADD COLUMN IF NOT EXISTS currency TEXT NOT NULL DEFAULT 'usd';

ALTER TABLE billing_sessions ADD COLUMN IF NOT EXISTS processed_event_id TEXT NOT NULL DEFAULT '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_sessions_external_unique ON billing_sessions(external_id) WHERE external_id <> '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_sessions_processed_event ON billing_sessions(processed_event_id) WHERE processed_event_id <> '';

CREATE TABLE IF NOT EXISTS stripe_deposit_events (
			event_id TEXT PRIMARY KEY,
			checkout_session_id TEXT NOT NULL UNIQUE,
			billing_session_id TEXT NOT NULL,
			account_id TEXT NOT NULL DEFAULT '',
			amount_micro_usd BIGINT NOT NULL,
			currency TEXT NOT NULL,
			status TEXT NOT NULL,
			reason TEXT NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_stripe_deposit_events_billing_session ON stripe_deposit_events(billing_session_id);

ALTER TABLE billing_sessions DROP COLUMN IF EXISTS chain;

CREATE TABLE IF NOT EXISTS users (
			account_id TEXT PRIMARY KEY,
			privy_user_id TEXT UNIQUE NOT NULL,
			email TEXT NOT NULL DEFAULT '',
			role TEXT NOT NULL DEFAULT '',
			platform_fee_percent BIGINT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE TABLE IF NOT EXISTS model_prices (
			account_id TEXT NOT NULL,
			model TEXT NOT NULL,
			input_price BIGINT NOT NULL,
			output_price BIGINT NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (account_id, model)
		);

DO $$ BEGIN
			IF NOT EXISTS (SELECT 1 FROM schema_migrations WHERE id = 'cleanup_wallet_model_prices_v1') THEN
				DELETE FROM model_prices
				WHERE account_id NOT IN (SELECT account_id FROM users)
				  AND account_id <> 'platform';
				INSERT INTO schema_migrations (id) VALUES ('cleanup_wallet_model_prices_v1');
			END IF;
		END $$;

ALTER TABLE users ADD COLUMN IF NOT EXISTS email TEXT NOT NULL DEFAULT '';

ALTER TABLE users DROP COLUMN IF EXISTS solana_wallet_address;

ALTER TABLE users DROP COLUMN IF EXISTS solana_wallet_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_privy ON users(privy_user_id);

DROP TABLE IF EXISTS supported_models;

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
			status TEXT NOT NULL DEFAULT 'beta',
			description TEXT NOT NULL DEFAULT '',
			runtime_parameters JSONB NOT NULL DEFAULT '{}',
			metadata JSONB NOT NULL DEFAULT '{}',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_model_registry_status ON model_registry(status);

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

ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_context_length INTEGER NOT NULL DEFAULT 0;

ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS max_output_length INTEGER NOT NULL DEFAULT 0;

ALTER TABLE model_registry ADD COLUMN IF NOT EXISTS runtime_parameters JSONB NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS idx_model_versions_model ON model_versions(model_id);

CREATE TABLE IF NOT EXISTS model_version_files (
			id BIGSERIAL PRIMARY KEY,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE CASCADE,
			path TEXT NOT NULL,
			size_bytes BIGINT NOT NULL,
			sha256 TEXT NOT NULL,
			role TEXT NOT NULL,
			UNIQUE(model_version_id, path)
		);

CREATE INDEX IF NOT EXISTS idx_model_version_files_version ON model_version_files(model_version_id);

CREATE TABLE IF NOT EXISTS model_active_versions (
			model_id TEXT PRIMARY KEY REFERENCES model_registry(id) ON DELETE CASCADE,
			model_version_id BIGINT NOT NULL REFERENCES model_versions(id) ON DELETE RESTRICT,
			activated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE TABLE IF NOT EXISTS publishing_api_keys (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			key_hash TEXT NOT NULL,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			last_used_at TIMESTAMPTZ
		);

CREATE UNIQUE INDEX IF NOT EXISTS idx_publishing_api_keys_hash ON publishing_api_keys(key_hash);

CREATE TABLE IF NOT EXISTS model_aliases (
			alias_id TEXT PRIMARY KEY,
			display_name TEXT NOT NULL DEFAULT '',
			builds JSONB NOT NULL DEFAULT '[]'::jsonb,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS desired_build TEXT NOT NULL DEFAULT '';

ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS previous_build TEXT NOT NULL DEFAULT '';

ALTER TABLE model_aliases ADD COLUMN IF NOT EXISTS retired_builds JSONB NOT NULL DEFAULT '[]'::jsonb;

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

DROP TABLE IF EXISTS model_migrations;

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

ALTER TABLE releases ADD COLUMN IF NOT EXISTS backend TEXT NOT NULL DEFAULT '';

ALTER TABLE releases ADD COLUMN IF NOT EXISTS metallib_hash TEXT NOT NULL DEFAULT '';

ALTER TABLE releases ADD COLUMN IF NOT EXISTS changelog TEXT NOT NULL DEFAULT '';

ALTER TABLE releases ADD COLUMN IF NOT EXISTS python_hash TEXT NOT NULL DEFAULT '';

ALTER TABLE releases ADD COLUMN IF NOT EXISTS runtime_hash TEXT NOT NULL DEFAULT '';

ALTER TABLE releases ADD COLUMN IF NOT EXISTS template_hashes TEXT NOT NULL DEFAULT '';

ALTER TABLE releases ADD COLUMN IF NOT EXISTS grpc_binary_hash TEXT NOT NULL DEFAULT '';

ALTER TABLE releases DROP COLUMN IF EXISTS image_bridge_hash;

CREATE TABLE IF NOT EXISTS device_codes (
			device_code TEXT PRIMARY KEY,
			user_code TEXT UNIQUE NOT NULL,
			account_id TEXT NOT NULL DEFAULT '',
			status TEXT NOT NULL DEFAULT 'pending',
			expires_at TIMESTAMPTZ NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_device_codes_user ON device_codes(user_code);

CREATE TABLE IF NOT EXISTS provider_tokens (
			token_hash TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			label TEXT NOT NULL DEFAULT '',
			active BOOLEAN NOT NULL DEFAULT TRUE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_provider_tokens_account ON provider_tokens(account_id);

CREATE TABLE IF NOT EXISTS invite_codes (
			code TEXT PRIMARY KEY,
			amount_micro_usd BIGINT NOT NULL,
			max_uses INTEGER NOT NULL DEFAULT 1,
			used_count INTEGER NOT NULL DEFAULT 0,
			active BOOLEAN NOT NULL DEFAULT TRUE,
			expires_at TIMESTAMPTZ,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE TABLE IF NOT EXISTS invite_redemptions (
			code TEXT NOT NULL REFERENCES invite_codes(code),
			account_id TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (code, account_id)
		);

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

CREATE INDEX IF NOT EXISTS idx_provider_earnings_account ON provider_earnings(account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_provider_earnings_provider ON provider_earnings(provider_key, created_at DESC);

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

INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
		 SELECT account_id, 'account', COUNT(*), COALESCE(SUM(amount_micro_usd), 0),
		        COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0), NOW()
		 FROM provider_earnings
		 WHERE account_id != ''
		 GROUP BY account_id
		 ON CONFLICT (key, key_type) DO NOTHING;

INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
		 SELECT provider_key, 'provider', COUNT(*), COALESCE(SUM(amount_micro_usd), 0),
		        COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0), NOW()
		 FROM provider_earnings
		 WHERE provider_key != ''
		 GROUP BY provider_key
		 ON CONFLICT (key, key_type) DO NOTHING;

CREATE TABLE IF NOT EXISTS provider_payouts (
			id BIGSERIAL PRIMARY KEY,
			provider_address TEXT NOT NULL,
			amount_micro_usd BIGINT NOT NULL,
			model TEXT NOT NULL DEFAULT '',
			job_id TEXT NOT NULL DEFAULT '',
			settled BOOLEAN NOT NULL DEFAULT FALSE,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_provider_payouts_address ON provider_payouts(provider_address, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_provider_payouts_settled ON provider_payouts(settled, created_at DESC);

ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_id TEXT NOT NULL DEFAULT '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_status TEXT NOT NULL DEFAULT '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_account_country TEXT NOT NULL DEFAULT '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_destination_type TEXT NOT NULL DEFAULT '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_destination_last4 TEXT NOT NULL DEFAULT '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS stripe_instant_eligible BOOLEAN NOT NULL DEFAULT FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_stripe_account ON users(stripe_account_id) WHERE stripe_account_id != '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT '';

ALTER TABLE users ADD COLUMN IF NOT EXISTS platform_fee_percent BIGINT;

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

CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_account ON stripe_withdrawals(account_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_withdrawals_transfer ON stripe_withdrawals(transfer_id) WHERE transfer_id != '';

CREATE UNIQUE INDEX IF NOT EXISTS idx_stripe_withdrawals_payout ON stripe_withdrawals(payout_id) WHERE payout_id != '';

CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_status ON stripe_withdrawals(status, created_at);

CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_stripe_account ON stripe_withdrawals(stripe_account_id, status);

ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS fee_refunded BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE stripe_withdrawals ADD COLUMN IF NOT EXISTS sweep_payout_id TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_stripe_withdrawals_sweep_payout ON stripe_withdrawals(sweep_payout_id) WHERE sweep_payout_id != '';

CREATE TABLE IF NOT EXISTS stripe_sweep_failures (
			payout_id TEXT PRIMARY KEY,
			failure_reason TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

ALTER TABLE balances ADD COLUMN IF NOT EXISTS withdrawable_micro_usd BIGINT NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS usage_totals (
			id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
			total_requests BIGINT NOT NULL DEFAULT 0,
			total_prompt_tokens BIGINT NOT NULL DEFAULT 0,
			total_completion_tokens BIGINT NOT NULL DEFAULT 0
		);

INSERT INTO usage_totals (id, total_requests, total_prompt_tokens, total_completion_tokens)
		 SELECT 1, COUNT(*), COALESCE(SUM(prompt_tokens), 0), COALESCE(SUM(completion_tokens), 0)
		 FROM usage
		 ON CONFLICT (id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_usage_request_location_notnull ON usage(created_at DESC) WHERE request_location IS NOT NULL;

CREATE TABLE IF NOT EXISTS provider_log_reports (
			id BIGSERIAL PRIMARY KEY,
			serial_number TEXT NOT NULL,
			provider_id TEXT NOT NULL DEFAULT '',
			account_id TEXT NOT NULL DEFAULT '',
			log_data BYTEA NOT NULL,
			log_size_bytes BIGINT NOT NULL DEFAULT 0,
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

CREATE INDEX IF NOT EXISTS idx_log_reports_serial ON provider_log_reports(serial_number, created_at DESC);

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

CREATE INDEX IF NOT EXISTS idx_provider_sessions_serial ON provider_sessions(serial_number, connected_at DESC);

CREATE INDEX IF NOT EXISTS idx_provider_sessions_connected ON provider_sessions(connected_at DESC);

CREATE INDEX IF NOT EXISTS idx_provider_sessions_open ON provider_sessions(connected_at) WHERE disconnected_at IS NULL;

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

CREATE INDEX IF NOT EXISTS idx_inference_routes_created ON inference_routes(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inference_routes_provider ON inference_routes(provider_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inference_routes_model ON inference_routes(model, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inference_routes_request ON inference_routes(request_id);

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

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS provider_region TEXT;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS consumer_region TEXT;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS parse_ms DOUBLE PRECISION;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS reserve_ms DOUBLE PRECISION;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS route_ms DOUBLE PRECISION;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS encrypt_ms DOUBLE PRECISION;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS queue_wait_ms DOUBLE PRECISION;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS dispatch_ms DOUBLE PRECISION;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS actual_decode_tps DOUBLE PRECISION;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS admitted_but_failed BOOL;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS used_backup BOOL;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS backup_won BOOL;

ALTER TABLE inference_routes ADD COLUMN IF NOT EXISTS error_reason TEXT;

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

CREATE INDEX IF NOT EXISTS idx_request_rejections_created ON request_rejections(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_request_rejections_reason ON request_rejections(reason_code, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_request_rejections_model ON request_rejections(resolved_model, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_request_rejections_status ON request_rejections(http_status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_request_rejections_servable ON request_rejections(could_have_served, created_at DESC) WHERE could_have_served = true;

CREATE TABLE IF NOT EXISTS code_attestations (
			se_pubkey TEXT PRIMARY KEY,
			version TEXT NOT NULL DEFAULT '',
			attested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			apns_token TEXT NOT NULL DEFAULT ''
		);

ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS apns_token TEXT NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS provider_trust_reuse (
			se_pubkey TEXT PRIMARY KEY,
			serial TEXT NOT NULL DEFAULT '',
			trust_level TEXT NOT NULL DEFAULT '',
			binary_hash TEXT NOT NULL DEFAULT '',
			sip_enabled BOOL NOT NULL DEFAULT FALSE,
			secure_boot_full BOOL NOT NULL DEFAULT FALSE,
			mda_udid TEXT NOT NULL DEFAULT '',
			verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		);

ALTER TABLE provider_sessions ADD COLUMN IF NOT EXISTS provider_key TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_provider_sessions_key ON provider_sessions(provider_key, connected_at) WHERE provider_key <> '';

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

CREATE INDEX IF NOT EXISTS idx_floor_draws_epoch ON provider_floor_draws(epoch_id);

CREATE INDEX IF NOT EXISTS idx_floor_draws_account ON provider_floor_draws(account_id, epoch_id);
