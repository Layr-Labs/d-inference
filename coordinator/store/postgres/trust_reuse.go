package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) ListProviderTrustReuse(ctx context.Context) ([]contracts.ProviderTrustReuse, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, serial, trust_level, last_verified_binary_hash,
		        sip_enabled, secure_boot_full, mda_udid,
		        hardware_proof_verified_at, application_proof_verified_at,
		        continuous_coverage_until,
		        evidence_generation, revocation_generation,
		        revocation_event_id, revoked_at
		   FROM provider_trust_reuse`)
	if err != nil {
		return nil, fmt.Errorf("store: list provider trust reuse: %w", err)
	}
	defer rows.Close()

	var out []contracts.ProviderTrustReuse
	for rows.Next() {
		var rec contracts.ProviderTrustReuse
		if err := rows.Scan(
			&rec.SEPubKey, &rec.Serial, &rec.TrustLevel,
			&rec.LastVerifiedBinaryHash, &rec.SIPEnabled,
			&rec.SecureBootFull, &rec.MDAUDID,
			&rec.HardwareProofVerifiedAt, &rec.ApplicationProofVerifiedAt,
			&rec.ContinuousCoverageUntil,
			&rec.EvidenceGeneration, &rec.RevocationGeneration,
			&rec.RevocationEventID, &rec.RevokedAt,
		); err != nil {
			return nil, fmt.Errorf("store: scan provider trust reuse: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate provider trust reuse: %w", err)
	}
	return out, nil
}

func (s *Store) UpsertProviderTrustReuse(ctx context.Context, rec contracts.ProviderTrustReuse, expectedRevocationGeneration uint64) (contracts.ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return contracts.ProviderTrustReuseWriteResult{}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var result contracts.ProviderTrustReuseWriteResult
	err := s.pool.QueryRow(ctx,
		`WITH written AS (
			INSERT INTO provider_trust_reuse (
				se_pubkey, serial, trust_level, binary_hash,
				last_verified_binary_hash, sip_enabled, secure_boot_full, mda_udid,
				verified_at, hardware_proof_verified_at,
				application_proof_verified_at, continuous_coverage_until,
				evidence_generation,
				revocation_generation, revocation_event_id, revoked_at)
			 VALUES ($1,$2,$3,$4,$4,$5,$6,$7,$8,$8,$9,$12,1,$10,$11,NULL)
			 ON CONFLICT (se_pubkey) DO UPDATE SET
				serial = EXCLUDED.serial,
				trust_level = EXCLUDED.trust_level,
				binary_hash = EXCLUDED.binary_hash,
				last_verified_binary_hash = EXCLUDED.last_verified_binary_hash,
				sip_enabled = EXCLUDED.sip_enabled,
				secure_boot_full = EXCLUDED.secure_boot_full,
				mda_udid = EXCLUDED.mda_udid,
				verified_at = EXCLUDED.verified_at,
				hardware_proof_verified_at = EXCLUDED.hardware_proof_verified_at,
				application_proof_verified_at = EXCLUDED.application_proof_verified_at,
				continuous_coverage_until = GREATEST(
					provider_trust_reuse.continuous_coverage_until,
					EXCLUDED.continuous_coverage_until),
				evidence_generation = provider_trust_reuse.evidence_generation + 1
			 WHERE provider_trust_reuse.revoked_at IS NULL
			   AND provider_trust_reuse.revocation_generation = EXCLUDED.revocation_generation
			 RETURNING evidence_generation, revocation_generation
		)
		SELECT TRUE, evidence_generation, revocation_generation FROM written
		UNION ALL
		SELECT FALSE, evidence_generation, revocation_generation
		  FROM provider_trust_reuse
		 WHERE se_pubkey = $1 AND NOT EXISTS (SELECT 1 FROM written)
		LIMIT 1`,
		rec.SEPubKey, rec.Serial, rec.TrustLevel,
		rec.LastVerifiedBinaryHash, rec.SIPEnabled, rec.SecureBootFull,
		rec.MDAUDID, rec.HardwareProofVerifiedAt,
		rec.ApplicationProofVerifiedAt, expectedRevocationGeneration,
		rec.RevocationEventID, rec.ContinuousCoverageUntil,
	).Scan(&result.Applied, &result.EvidenceGeneration, &result.RevocationGeneration)
	if err != nil {
		return contracts.ProviderTrustReuseWriteResult{}, fmt.Errorf("store: upsert provider trust reuse: %w", err)
	}
	return result, nil
}

func (s *Store) RecoverProviderTrustReuse(ctx context.Context, rec contracts.ProviderTrustReuse, expectedRevocationGeneration uint64) (contracts.ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return contracts.ProviderTrustReuseWriteResult{}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var result contracts.ProviderTrustReuseWriteResult
	err := s.pool.QueryRow(ctx,
		`WITH written AS (
			INSERT INTO provider_trust_reuse (
				se_pubkey, serial, trust_level, binary_hash,
				last_verified_binary_hash, sip_enabled, secure_boot_full, mda_udid,
				verified_at, hardware_proof_verified_at,
				application_proof_verified_at, continuous_coverage_until,
				evidence_generation,
				revocation_generation, revocation_event_id, revoked_at)
			 VALUES ($1,$2,$3,$4,$4,$5,$6,$7,$8,$8,$9,$12,1,$10,$11,NULL)
			 ON CONFLICT (se_pubkey) DO UPDATE SET
				serial = EXCLUDED.serial,
				trust_level = EXCLUDED.trust_level,
				binary_hash = EXCLUDED.binary_hash,
				last_verified_binary_hash = EXCLUDED.last_verified_binary_hash,
				sip_enabled = EXCLUDED.sip_enabled,
				secure_boot_full = EXCLUDED.secure_boot_full,
				mda_udid = EXCLUDED.mda_udid,
				verified_at = EXCLUDED.verified_at,
				hardware_proof_verified_at = EXCLUDED.hardware_proof_verified_at,
				application_proof_verified_at = EXCLUDED.application_proof_verified_at,
				continuous_coverage_until = GREATEST(
					provider_trust_reuse.continuous_coverage_until,
					EXCLUDED.continuous_coverage_until),
				evidence_generation = provider_trust_reuse.evidence_generation + 1,
				revoked_at = NULL
			 WHERE provider_trust_reuse.revocation_generation = EXCLUDED.revocation_generation
			 RETURNING evidence_generation, revocation_generation
		)
		SELECT TRUE, evidence_generation, revocation_generation FROM written
		UNION ALL
		SELECT FALSE, evidence_generation, revocation_generation
		  FROM provider_trust_reuse
		 WHERE se_pubkey = $1 AND NOT EXISTS (SELECT 1 FROM written)
		LIMIT 1`,
		rec.SEPubKey, rec.Serial, rec.TrustLevel,
		rec.LastVerifiedBinaryHash, rec.SIPEnabled, rec.SecureBootFull,
		rec.MDAUDID, rec.HardwareProofVerifiedAt,
		rec.ApplicationProofVerifiedAt, expectedRevocationGeneration,
		rec.RevocationEventID, rec.ContinuousCoverageUntil,
	).Scan(&result.Applied, &result.EvidenceGeneration, &result.RevocationGeneration)
	if err != nil {
		return contracts.ProviderTrustReuseWriteResult{}, fmt.Errorf("store: recover provider trust reuse: %w", err)
	}
	return result, nil
}

func (s *Store) RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (contracts.ProviderTrustReuse, error) {
	if seKey == "" || revocationEventID == "" {
		return contracts.ProviderTrustReuse{}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var rec contracts.ProviderTrustReuse
	err := s.pool.QueryRow(ctx,
		`WITH revoked AS (
			INSERT INTO provider_trust_reuse (
				se_pubkey, trust_level, revoked_at, revocation_generation,
				revocation_event_id)
			 VALUES ($1, '', NOW(), 1, $2)
			 ON CONFLICT (se_pubkey) DO UPDATE SET
				trust_level = '',
				revoked_at = NOW(),
				continuous_coverage_until = NULL,
				revocation_generation = provider_trust_reuse.revocation_generation + 1,
				revocation_event_id = EXCLUDED.revocation_event_id
			 WHERE provider_trust_reuse.revocation_event_id
			       IS DISTINCT FROM EXCLUDED.revocation_event_id
			 RETURNING se_pubkey, serial, trust_level,
				last_verified_binary_hash, sip_enabled, secure_boot_full,
				mda_udid, hardware_proof_verified_at,
				application_proof_verified_at, continuous_coverage_until,
				evidence_generation,
				revocation_generation, revocation_event_id, revoked_at
		)
		SELECT se_pubkey, serial, trust_level, last_verified_binary_hash,
		       sip_enabled, secure_boot_full, mda_udid,
		       hardware_proof_verified_at, application_proof_verified_at,
		       continuous_coverage_until,
		       evidence_generation, revocation_generation,
		       revocation_event_id, revoked_at
		  FROM revoked
		UNION ALL
		SELECT se_pubkey, serial, trust_level, last_verified_binary_hash,
		       sip_enabled, secure_boot_full, mda_udid,
		       hardware_proof_verified_at, application_proof_verified_at,
		       continuous_coverage_until,
		       evidence_generation, revocation_generation,
		       revocation_event_id, revoked_at
		  FROM provider_trust_reuse
		 WHERE se_pubkey = $1 AND NOT EXISTS (SELECT 1 FROM revoked)
		LIMIT 1`,
		seKey, revocationEventID,
	).Scan(
		&rec.SEPubKey, &rec.Serial, &rec.TrustLevel,
		&rec.LastVerifiedBinaryHash, &rec.SIPEnabled,
		&rec.SecureBootFull, &rec.MDAUDID,
		&rec.HardwareProofVerifiedAt, &rec.ApplicationProofVerifiedAt,
		&rec.ContinuousCoverageUntil,
		&rec.EvidenceGeneration, &rec.RevocationGeneration,
		&rec.RevocationEventID, &rec.RevokedAt,
	)
	if err != nil {
		return contracts.ProviderTrustReuse{}, fmt.Errorf("store: revoke provider trust reuse: %w", err)
	}
	return rec, nil
}

func (s *Store) AdvanceProviderTrustReuseCoverage(ctx context.Context, seKeys []string, until time.Time) error {
	if len(seKeys) == 0 || until.IsZero() {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// One batched pass; GREATEST keeps the watermark monotonic and a
	// tombstoned/non-hardware row is never touched (revocation wins).
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_trust_reuse
		    SET continuous_coverage_until = GREATEST(continuous_coverage_until, $2::timestamptz)
		  WHERE se_pubkey = ANY($1)
		    AND revoked_at IS NULL
		    AND trust_level = 'hardware'`,
		seKeys, until)
	if err != nil {
		return fmt.Errorf("store: advance provider trust reuse coverage: %w", err)
	}
	return nil
}
