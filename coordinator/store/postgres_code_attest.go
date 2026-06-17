package store

import (
	"context"
	"fmt"
	"time"
)

func (s *PostgresStore) ListCodeAttestations(ctx context.Context) ([]CodeAttestation, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT se_pubkey, version, attested_at, apns_token FROM code_attestations`)
	if err != nil {
		return nil, fmt.Errorf("store: list code attestations: %w", err)
	}
	defer rows.Close()

	var out []CodeAttestation
	for rows.Next() {
		var rec CodeAttestation
		if err := rows.Scan(&rec.SEPubKey, &rec.Version, &rec.AttestedAt, &rec.APNsToken); err != nil {
			return nil, fmt.Errorf("store: scan code attestation: %w", err)
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: iterate code attestations: %w", err)
	}
	return out, nil
}

func (s *PostgresStore) UpsertCodeAttestation(ctx context.Context, rec CodeAttestation) error {
	if rec.SEPubKey == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO code_attestations (se_pubkey, version, attested_at, apns_token)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (se_pubkey) DO UPDATE SET
			version = $2, attested_at = $3, apns_token = $4`,
		rec.SEPubKey, rec.Version, rec.AttestedAt, rec.APNsToken,
	)
	if err != nil {
		return fmt.Errorf("store: upsert code attestation: %w", err)
	}
	return nil
}

func (s *PostgresStore) DeleteCodeAttestation(ctx context.Context, seKey string) error {
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
