package schema

func codeAttestation() []string {
	return []string{

		// APNs code-identity attestation reuse cache (W5 Fix 2). Persists the
		// in-memory reuse cache so a blue-green deploy / restart does not wipe it
		// and provoke a fleet-wide push storm against Apple's ~3/hour/device push
		// budget. One row per device (keyed by Secure Enclave public key). The
		// row records that the device completed a FULL code-identity round-trip at
		// attested_at on binary version; the freshness + version gate is applied on
		// READ (in the coordinator), so a stale/wrong-version row never extends
		// trust — it only lets the coordinator skip a redundant push.
		`CREATE TABLE IF NOT EXISTS code_attestations (
			se_pubkey TEXT PRIMARY KEY,
			version TEXT NOT NULL DEFAULT '',
			attested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			apns_token TEXT NOT NULL DEFAULT '',
			node_public_key TEXT NOT NULL DEFAULT '',
			binary_hash TEXT NOT NULL DEFAULT ''
		)`,
		// Token-binding column for reuse (Codex #7): additive for DBs whose
		// code_attestations table predates it (the CREATE above is a no-op there).
		`ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS apns_token TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS node_public_key TEXT NOT NULL DEFAULT ''`,
		// Attested binary identity (Codex 05:55Z P1): additive; a pre-existing
		// row's empty hash marks a legacy identity-less proof, which never
		// authorizes a release-transition resume (real APNs challenge instead).
		`ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS binary_hash TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE code_attestations ADD COLUMN IF NOT EXISTS continuous_coverage_until TIMESTAMPTZ`,
		// Durable APNs admission state is deliberately separate from successful
		// attestation evidence. Spending a push budget never creates trust.
		`CREATE TABLE IF NOT EXISTS code_attest_push_budgets (
			se_pubkey TEXT NOT NULL,
			token_hash TEXT NOT NULL DEFAULT '',
			next_push_at TIMESTAMPTZ NOT NULL,
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			PRIMARY KEY (se_pubkey, token_hash)
		)`,
		`DO $$
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
		END $$`,
		`CREATE INDEX IF NOT EXISTS idx_code_attest_push_budgets_due
			ON code_attest_push_budgets(next_push_at)`,
		// Durable rotation-clear cooldown (Codex 06:36Z P1): the sentinel row
		// records the last honored floor clear so restart/blue-green peers
		// share one anti-abuse clear budget. NULL = never cleared (legacy rows
		// and fresh sentinels clear immediately, preserving genuine-rotation UX).
		`ALTER TABLE code_attest_push_budgets
			ADD COLUMN IF NOT EXISTS last_clear_at TIMESTAMPTZ`,
	}
}
