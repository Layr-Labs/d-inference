-- Exact serving statement from commit 884d97862, before the fast-startup changes.
WITH earning AS (
			INSERT INTO provider_earnings (
				account_id, provider_id, provider_key, job_id, model, amount_micro_usd, prompt_tokens, completion_tokens, created_at
			) VALUES ($1, $6, $7, $4, $8, $2, $9, $10, COALESCE($5::timestamptz, NOW()))
			ON CONFLICT (job_id) WHERE job_id <> '' DO NOTHING
			RETURNING account_id, provider_key, amount_micro_usd, prompt_tokens, completion_tokens
		), credit AS (
			INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			SELECT account_id, amount_micro_usd, amount_micro_usd, NOW() FROM earning
			ON CONFLICT (account_id) DO UPDATE SET
			  balance_micro_usd = balances.balance_micro_usd + EXCLUDED.balance_micro_usd,
			  withdrawable_micro_usd = balances.withdrawable_micro_usd + EXCLUDED.withdrawable_micro_usd,
			  updated_at = NOW()
			RETURNING balance_micro_usd
		), ledger AS (
			INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference, created_at)
			SELECT e.account_id, $3, e.amount_micro_usd, c.balance_micro_usd, $4, COALESCE($5::timestamptz, NOW())
			FROM earning e CROSS JOIN credit c
		), summary_account AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT account_id, 'account', 1, amount_micro_usd, prompt_tokens, completion_tokens, NOW() FROM earning
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + 1,
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			  total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			  updated_at = NOW()
		), summary_provider AS (
			INSERT INTO earnings_summary (key, key_type, total_count, total_micro_usd, total_prompt_tokens, total_completion_tokens, updated_at)
			SELECT provider_key, 'provider', 1, amount_micro_usd, prompt_tokens, completion_tokens, NOW() FROM earning
			WHERE provider_key <> ''
			ON CONFLICT (key, key_type) DO UPDATE SET
			  total_count = earnings_summary.total_count + 1,
			  total_micro_usd = earnings_summary.total_micro_usd + EXCLUDED.total_micro_usd,
			  total_prompt_tokens = earnings_summary.total_prompt_tokens + EXCLUDED.total_prompt_tokens,
			  total_completion_tokens = earnings_summary.total_completion_tokens + EXCLUDED.total_completion_tokens,
			  updated_at = NOW()
		)
		SELECT COALESCE((SELECT balance_micro_usd FROM credit), 0)
