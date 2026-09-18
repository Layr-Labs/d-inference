-- Exact floor-settlement statement from base rewards introduction, commit 053f8c220 (2026-06-20).
WITH draw AS (
			INSERT INTO provider_floor_draws (provider_key, account_id, epoch_id, amount_micro_usd,
				floor_micro_usd, earned_micro_usd, uptime_frac, memory_gb, created_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
			ON CONFLICT (provider_key, epoch_id) DO NOTHING
			RETURNING account_id, amount_micro_usd
		), credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			SELECT account_id, amount_micro_usd, amount_micro_usd, NOW() FROM draw WHERE amount_micro_usd > 0
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT d.account_id, $9, d.amount_micro_usd, c.balance_micro_usd, $3, NOW()
			FROM draw d CROSS JOIN credit c WHERE d.amount_micro_usd > 0
		), earning AS (
			INSERT INTO provider_earnings (account_id, provider_id, provider_key, job_id, model,
				amount_micro_usd, prompt_tokens, completion_tokens, created_at)
			SELECT d.account_id, '', $1, $10, 'base_reward', d.amount_micro_usd, 0, 0, NOW()
			FROM draw d WHERE d.amount_micro_usd > 0
			ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
			RETURNING account_id, provider_key, amount_micro_usd
		), summary_account AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT account_id, 'account', 0, amount_micro_usd, 0, 0, NOW() FROM earning
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  updated_at = NOW()
		), summary_provider AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT provider_key, 'provider', 0, amount_micro_usd, 0, 0, NOW() FROM earning WHERE provider_key <> ''
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  updated_at = NOW()
		)
		SELECT EXISTS (SELECT 1 FROM draw)
