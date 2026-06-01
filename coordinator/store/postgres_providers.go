package store

import (
	"context"
	"fmt"
	"time"

	"encoding/json"
)

// --- Provider Fleet Persistence ---

// providerColumns is the canonical SELECT column list for the providers table,
// in the exact order scanProviderRow expects. All provider read paths share it
// so the column set and scan order can never drift.
const providerColumns = `id, hardware, models, backend, location, trust_level, attested,
		attestation_result, se_public_key, serial_number,
		mda_verified, mda_cert_chain, acme_verified,
		version, runtime_verified, python_hash, runtime_hash,
		last_challenge_verified, failed_challenges, account_id,
		lifetime_requests_served, lifetime_tokens_generated,
		last_session_requests_served, last_session_tokens_generated,
		registered_at, last_seen`

// scanProviderRow scans one providers row (selected with providerColumns) into a
// ProviderRecord, decoding the JSON location column. Works for both pgx.Row
// (QueryRow) and pgx.Rows (iteration) via rowScanner.
func scanProviderRow(row rowScanner) (*ProviderRecord, error) {
	var p ProviderRecord
	var locationRaw []byte
	if err := row.Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&locationRaw,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.RegisteredAt, &p.LastSeen,
	); err != nil {
		return nil, err
	}
	p.Location = unmarshalProviderLocation(locationRaw)
	return &p, nil
}

func (s *PostgresStore) UpsertProvider(ctx context.Context, p ProviderRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO providers (
			id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7,
			$8, $9, $10,
			$11, $12, $13,
			$14, $15, $16, $17,
			$18, $19, $20,
			$21, $22, $23, $24,
			$25, $26
		)
		ON CONFLICT (id) DO UPDATE SET
			hardware = $2, models = $3, backend = $4, location = $5,
			trust_level = $6, attested = $7,
			attestation_result = $8, se_public_key = $9, serial_number = $10,
			mda_verified = $11, mda_cert_chain = $12, acme_verified = $13,
			version = $14, runtime_verified = $15, python_hash = $16, runtime_hash = $17,
			last_challenge_verified = $18, failed_challenges = $19, account_id = $20,
			lifetime_requests_served = $21, lifetime_tokens_generated = $22,
			last_session_requests_served = $23, last_session_tokens_generated = $24,
			last_seen = $26`,
		p.ID, p.Hardware, p.Models, p.Backend,
		marshalProviderLocation(p.Location),
		p.TrustLevel, p.Attested,
		p.AttestationResult, p.SEPublicKey, p.SerialNumber,
		p.MDAVerified, p.MDACertChain, p.ACMEVerified,
		p.Version, p.RuntimeVerified, p.PythonHash, p.RuntimeHash,
		p.LastChallengeVerified, p.FailedChallenges, p.AccountID,
		p.LifetimeRequestsServed, p.LifetimeTokensGenerated,
		p.LastSessionRequestsServed, p.LastSessionTokensGenerated,
		p.RegisteredAt, p.LastSeen,
	)
	if err != nil {
		return fmt.Errorf("store: upsert provider: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	p, err := scanProviderRow(s.pool.QueryRow(ctx,
		`SELECT `+providerColumns+` FROM providers WHERE id = $1`, id))
	if err != nil {
		return nil, fmt.Errorf("store: provider not found: %w", err)
	}
	return p, nil
}

func (s *PostgresStore) GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	p, err := scanProviderRow(s.pool.QueryRow(ctx,
		`SELECT `+providerColumns+` FROM providers WHERE serial_number = $1 AND serial_number != ''
		 ORDER BY last_seen DESC LIMIT 1`, serial))
	if err != nil {
		return nil, fmt.Errorf("store: provider with serial not found: %w", err)
	}
	return p, nil
}

func (s *PostgresStore) ListProviderRecords(ctx context.Context) ([]ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+providerColumns+` FROM providers ORDER BY last_seen DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list providers: %w", err)
	}
	defer rows.Close()

	records := []ProviderRecord{}
	for rows.Next() {
		p, err := scanProviderRow(rows)
		if err != nil {
			continue
		}
		records = append(records, *p)
	}
	return records, nil
}

func (s *PostgresStore) ListProvidersByAccount(ctx context.Context, accountID string) ([]ProviderRecord, error) {
	if accountID == "" {
		return []ProviderRecord{}, nil
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	// Dedupe in SQL: many session UUIDs can map to the same physical
	// machine (one row per reconnect). Pick the most-recent row per
	// stable identity (serial → SE key → id) so we don't return tens
	// of thousands of historical rows for accounts with churny providers.
	rows, err := s.pool.Query(ctx,
		`SELECT DISTINCT ON (
			COALESCE(NULLIF(serial_number, ''),
			         NULLIF(se_public_key, ''),
			         id)
		 )
		 `+providerColumns+`
		 FROM providers
		 WHERE account_id = $1
		 ORDER BY COALESCE(NULLIF(serial_number, ''),
		                   NULLIF(se_public_key, ''),
		                   id),
		          last_seen DESC`,
		accountID,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list providers by account: %w", err)
	}
	defer rows.Close()

	records := make([]ProviderRecord, 0)
	for rows.Next() {
		p, err := scanProviderRow(rows)
		if err != nil {
			continue
		}
		records = append(records, *p)
	}
	return records, nil
}

func (s *PostgresStore) UpdateProviderLastSeen(ctx context.Context, id string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET last_seen = NOW() WHERE id = $1`, id,
	)
	if err != nil {
		return fmt.Errorf("store: update provider last_seen: %w", err)
	}
	return nil
}

func (s *PostgresStore) UpdateProviderTrust(ctx context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET trust_level = $2, attested = $3, attestation_result = $4
		 WHERE id = $1`,
		id, trustLevel, attested, attestationResult,
	)
	if err != nil {
		return fmt.Errorf("store: update provider trust: %w", err)
	}
	return nil
}

func (s *PostgresStore) UpdateProviderChallenge(ctx context.Context, id string, lastVerified time.Time, failedCount int) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET last_challenge_verified = $2, failed_challenges = $3
		 WHERE id = $1`,
		id, lastVerified, failedCount,
	)
	if err != nil {
		return fmt.Errorf("store: update provider challenge: %w", err)
	}
	return nil
}

func (s *PostgresStore) UpdateProviderRuntime(ctx context.Context, id string, verified bool, pythonHash, runtimeHash string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`UPDATE providers SET runtime_verified = $2, python_hash = $3, runtime_hash = $4
		 WHERE id = $1`,
		id, verified, pythonHash, runtimeHash,
	)
	if err != nil {
		return fmt.Errorf("store: update provider runtime: %w", err)
	}
	return nil
}
