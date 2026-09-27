package store

import (
	"context"
	"fmt"
	"time"
)

// providerRecordColumns and scanProviderRecord are the single projection for
// durable provider identity, trust facts and lifetime/session counters.
const providerRecordColumns = `id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key`

func scanProviderRecord(row rowScanner) (*ProviderRecord, error) {
	var p ProviderRecord
	var locationRaw []byte
	if err := row.Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&locationRaw,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.LifetimeStats, &p.LastSessionStats,
		&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
	); err != nil {
		return nil, err
	}
	p.Location = unmarshalProviderLocation(locationRaw)
	return &p, nil
}

func (s *PostgresStore) GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	p, err := scanProviderRecord(s.pool.QueryRow(ctx, `SELECT `+providerRecordColumns+` FROM providers WHERE id = $1`, id))
	if err != nil {
		return nil, fmt.Errorf("store: provider not found: %w", err)
	}
	return p, nil
}

func (s *PostgresStore) GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	p, err := scanProviderRecord(s.pool.QueryRow(ctx, `SELECT `+providerRecordColumns+`
		FROM providers WHERE serial_number = $1 AND serial_number != ''
		ORDER BY last_seen DESC LIMIT 1`, serial))
	if err != nil {
		return nil, fmt.Errorf("store: provider with serial not found: %w", err)
	}
	return p, nil
}
