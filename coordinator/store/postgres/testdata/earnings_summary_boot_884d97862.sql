-- Exact legacy boot statements from 884d97862; introduced before base rewards in de67e28f5 (2026-05-27).
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
