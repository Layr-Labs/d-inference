package store

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// Keep two bounded queries rather than an OR over identity columns: each uses
// an ordered partial index and stops at the newest matching prior session.
func (s *PostgresStore) GetProviderForRestore(ctx context.Context, serial, seKey string, excludeIDs []string) (*ProviderRecord, error) {
	if excludeIDs == nil {
		excludeIDs = []string{}
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	for _, identity := range []struct{ column, value string }{
		{"serial_number", serial}, {"se_public_key", seKey},
	} {
		if identity.value == "" {
			continue
		}
		var p ProviderRecord
		var locationRaw []byte
		// column comes exclusively from the fixed literals above, never a caller.
		err := s.pool.QueryRow(ctx, `SELECT id, hardware, models, backend, location,
			trust_level, attested, attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats, registered_at, last_seen, public_key
			FROM providers WHERE `+identity.column+` = $1 AND `+identity.column+` <> '' AND id <> ALL($2::text[])
			ORDER BY last_seen DESC, id DESC LIMIT 1`, identity.value, excludeIDs).Scan(
			&p.ID, &p.Hardware, &p.Models, &p.Backend, &locationRaw,
			&p.TrustLevel, &p.Attested, &p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
			&p.MDAVerified, &p.MDACertChain, &p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
			&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
			&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
			&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
			&p.LifetimeStats, &p.LastSessionStats, &p.RegisteredAt, &p.LastSeen, &p.PublicKey,
		)
		if errors.Is(err, pgx.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("store: lookup provider for restore: %w", err)
		}
		p.Location = unmarshalProviderLocation(locationRaw)
		return &p, nil
	}
	return nil, nil
}

func (s *MemoryStore) GetProviderForRestore(ctx context.Context, serial, seKey string, excludeIDs []string) (*ProviderRecord, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var serialMatch, keyMatch *ProviderRecord
	for _, p := range s.providerRecords {
		if slices.Contains(excludeIDs, p.ID) {
			continue
		}
		if serial != "" && p.SerialNumber == serial && newerProviderRecord(p, serialMatch) {
			serialMatch = p
		}
		if seKey != "" && p.SEPublicKey == seKey && newerProviderRecord(p, keyMatch) {
			keyMatch = p
		}
	}
	best := serialMatch
	if best == nil {
		best = keyMatch
	}
	if best == nil {
		return nil, nil
	}
	cp := *best
	if best.Location != nil {
		loc := *best.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func newerProviderRecord(p, prior *ProviderRecord) bool {
	return prior == nil || p.LastSeen.After(prior.LastSeen) || (p.LastSeen.Equal(prior.LastSeen) && p.ID > prior.ID)
}
