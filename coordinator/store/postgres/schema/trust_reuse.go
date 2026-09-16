package schema

func trustReuse() []string {
	return []string{

		// Durable provider device evidence. The legacy binary_hash/verified_at
		// columns remain accepted during migration, but application proof is never
		// fabricated from them.
		`CREATE TABLE IF NOT EXISTS provider_trust_reuse (
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
		)`,
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS last_verified_binary_hash TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS hardware_proof_verified_at TIMESTAMPTZ`,
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS application_proof_verified_at TIMESTAMPTZ`,
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS evidence_generation BIGINT NOT NULL DEFAULT 1`,
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS revocation_generation BIGINT NOT NULL DEFAULT 0`,
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS revocation_event_id TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ`,
		// Coordinator-measured continuous-liveness watermark (connection
		// continuity trust reuse). Written only by the coordinator; NULL for
		// pre-migration rows means "no continuity evidence" (fail-safe).
		`ALTER TABLE provider_trust_reuse ADD COLUMN IF NOT EXISTS continuous_coverage_until TIMESTAMPTZ`,
		`UPDATE provider_trust_reuse
		 SET hardware_proof_verified_at = verified_at
		 WHERE hardware_proof_verified_at IS NULL`,
		`UPDATE provider_trust_reuse
		 SET last_verified_binary_hash = binary_hash
		 WHERE last_verified_binary_hash = '' AND binary_hash <> ''`,
		`ALTER TABLE provider_trust_reuse ALTER COLUMN hardware_proof_verified_at SET DEFAULT NOW()`,
		`ALTER TABLE provider_trust_reuse ALTER COLUMN hardware_proof_verified_at SET NOT NULL`,
	}
}
