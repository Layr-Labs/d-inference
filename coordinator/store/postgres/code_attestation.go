package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) ListCodeAttestations(ctx context.Context) ([]contracts.CodeAttestation, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, version, attested_at, apns_token, node_public_key, binary_hash, continuous_coverage_until FROM code_attestations`)
	if err != nil {
		return nil, fmt.Errorf("store: list code attestations: %w", err)
	}
	defer rows.Close()

	var out []contracts.CodeAttestation
	for rows.Next() {
		var rec contracts.CodeAttestation
		if err := rows.Scan(
			&rec.SEPubKey, &rec.Version, &rec.AttestedAt,
			&rec.APNsToken, &rec.NodePublicKey, &rec.BinaryHash, &rec.ContinuousCoverageUntil,
		); err != nil {
			return nil, fmt.Errorf("store: scan code attestation: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate code attestations: %w", err)
	}
	return out, nil
}

func (s *Store) UpsertCodeAttestation(ctx context.Context, rec contracts.CodeAttestation) error {
	if rec.SEPubKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO code_attestations (
			se_pubkey, version, attested_at, apns_token, node_public_key, binary_hash, continuous_coverage_until
		 ) VALUES ($1, $2, $3, $4, $5, $6, $7)
		 ON CONFLICT (se_pubkey) DO UPDATE SET
			version = $2, attested_at = $3,
			apns_token = $4, node_public_key = $5, binary_hash = $6,
			continuous_coverage_until = CASE WHEN code_attestations.attested_at = EXCLUDED.attested_at
             AND code_attestations.version = EXCLUDED.version AND code_attestations.apns_token = EXCLUDED.apns_token
             AND code_attestations.node_public_key = EXCLUDED.node_public_key AND code_attestations.binary_hash = EXCLUDED.binary_hash
             THEN GREATEST(code_attestations.continuous_coverage_until,EXCLUDED.continuous_coverage_until)
             ELSE EXCLUDED.continuous_coverage_until END
		 WHERE code_attestations.attested_at <= EXCLUDED.attested_at`,
		rec.SEPubKey, rec.Version, rec.AttestedAt,
		rec.APNsToken, rec.NodePublicKey, rec.BinaryHash, rec.ContinuousCoverageUntil,
	)
	if err != nil {
		return fmt.Errorf("store: upsert code attestation: %w", err)
	}
	return nil
}

func (s *Store) DeleteCodeAttestation(ctx context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	if _, err := s.pool.Exec(ctx, `DELETE FROM code_attestations WHERE se_pubkey = $1`, seKey); err != nil {
		return fmt.Errorf("store: delete code attestation: %w", err)
	}
	return nil
}
