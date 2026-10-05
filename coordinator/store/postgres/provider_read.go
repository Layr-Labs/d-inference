package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// providerRecordColumns and scanProviderRecord are the single projection for
// durable provider identity, trust facts and lifetime/session counters.
const providerRecordColumns = `id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key`

func scanProviderRecord(row rowScanner) (*store.ProviderRecord, error) {
	var p store.ProviderRecord
	var locationRaw []byte
	if err := row.Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&locationRaw,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain,
		&p.Version, &p.RuntimeVerified,
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

func (s *PostgresStore) GetProviderRecord(ctx context.Context, id string) (*store.ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	p, err := scanProviderRecord(s.pool.QueryRow(ctx, `SELECT `+providerRecordColumns+` FROM providers WHERE id = $1 AND deleted_at IS NULL`, id))
	if err != nil {
		return nil, fmt.Errorf("store: provider not found: %w", err)
	}
	return p, nil
}
