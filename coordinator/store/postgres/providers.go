package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

func marshalProviderLocation(loc *store.ProviderLocation) json.RawMessage {
	if loc == nil {
		return nil
	}
	b, err := json.Marshal(loc)
	if err != nil {
		return nil
	}
	return b
}

func unmarshalProviderLocation(raw []byte) *store.ProviderLocation {
	if len(raw) == 0 {
		return nil
	}
	var loc store.ProviderLocation
	if err := json.Unmarshal(raw, &loc); err != nil {
		return nil
	}
	return &loc
}

func providerStatsJSON(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return json.RawMessage(`{}`)
	}
	return raw
}

func (s *PostgresStore) UpsertProvider(ctx context.Context, p store.ProviderRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	return upsertProviderRecord(ctx, s.pool, p)
}

// upsertProviderRecord leaves a soft-deleted row alone: the account is under
// erasure and a late heartbeat persist must not rewrite its serial or location.
func upsertProviderRecord(ctx context.Context, db providerRecordDB, p store.ProviderRecord) error {
	_, err := db.Exec(ctx,
		`INSERT INTO providers (
			id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7,
			$8, $9, $10,
			$11, $12,
			$13, $14, $15, $16,
			$17, $18, $19,
			$20, $21, $22, $23,
			$24, $25,
			$26, $27, $28
		)
		ON CONFLICT (id) DO UPDATE SET
			hardware = $2, models = $3, backend = $4, location = $5,
			trust_level = $6, attested = $7,
			attestation_result = $8, se_public_key = $9, serial_number = $10,
			mda_verified = $11, mda_cert_chain = $12,
			version = $13, runtime_verified = $14, python_hash = $15, runtime_hash = $16,
			last_challenge_verified = $17, failed_challenges = $18, account_id = $19,
			lifetime_requests_served = $20, lifetime_tokens_generated = $21,
			last_session_requests_served = $22, last_session_tokens_generated = $23,
			lifetime_stats = $24, last_session_stats = $25,
			last_seen = $27, public_key = $28
		WHERE providers.deleted_at IS NULL`,
		p.ID, p.Hardware, p.Models, p.Backend,
		marshalProviderLocation(p.Location),
		p.TrustLevel, p.Attested,
		p.AttestationResult, p.SEPublicKey, p.SerialNumber,
		p.MDAVerified, p.MDACertChain,
		p.Version, p.RuntimeVerified, "", "", // retired python_hash, runtime_hash columns
		p.LastChallengeVerified, p.FailedChallenges, p.AccountID,
		p.LifetimeRequestsServed, p.LifetimeTokensGenerated,
		p.LastSessionRequestsServed, p.LastSessionTokensGenerated,
		providerStatsJSON(p.LifetimeStats), providerStatsJSON(p.LastSessionStats),
		p.RegisteredAt, p.LastSeen, p.PublicKey,
	)
	if err != nil {
		return fmt.Errorf("store: upsert provider: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetMDAChainBySerial(ctx context.Context, serial string) (json.RawMessage, error) {
	if serial == "" {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// Newest NON-EMPTY chain for the serial — skips a reconnect's empty row that
	// would otherwise shadow a still-valid chain from a prior connection.
	var chain json.RawMessage
	err := s.pool.QueryRow(ctx,
		`SELECT mda_cert_chain FROM providers
		 WHERE serial_number = $1 AND serial_number != '' AND mda_cert_chain IS NOT NULL
		   AND deleted_at IS NULL
		 ORDER BY last_seen DESC LIMIT 1`, serial,
	).Scan(&chain)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, fmt.Errorf("store: get mda chain by serial: %w", err)
	}
	return chain, nil
}

func (s *PostgresStore) ListProvidersByAccount(ctx context.Context, accountID string) ([]store.ProviderRecord, error) {
	if accountID == "" {
		return []store.ProviderRecord{}, nil
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
		 id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain,
			version, runtime_verified,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			lifetime_stats, last_session_stats,
			registered_at, last_seen, public_key
		 FROM providers
		 WHERE account_id = $1 AND deleted_at IS NULL
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

	records := make([]store.ProviderRecord, 0)
	for rows.Next() {
		var p store.ProviderRecord
		var locationRaw []byte
		if err := rows.Scan(
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
			continue
		}
		p.Location = unmarshalProviderLocation(locationRaw)
		records = append(records, p)
	}
	return records, nil
}

func (s *PostgresStore) DeleteProvidersBySerial(ctx context.Context, ownerAccountID, serialOrID string) (int, error) {
	if ownerAccountID == "" || serialOrID == "" {
		return 0, nil
	}

	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("store: delete providers begin: %w", err)
	}
	defer tx.Rollback(ctx)

	// Resolve all provider rows for this owner matching the stable identity
	// (serial OR session id). Postgres keeps one row per session UUID, so a
	// serial can map to many ids — delete them all.
	rows, err := tx.Query(ctx,
		`SELECT id FROM providers
		 WHERE account_id = $1
		   AND ((serial_number = $2 AND serial_number <> '') OR id = $2)`,
		ownerAccountID, serialOrID,
	)
	if err != nil {
		return 0, fmt.Errorf("store: delete providers select: %w", err)
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, fmt.Errorf("store: delete providers scan: %w", err)
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("store: delete providers iterate: %w", err)
	}
	if len(ids) == 0 {
		if err := tx.Commit(ctx); err != nil {
			return 0, fmt.Errorf("store: delete providers commit: %w", err)
		}
		return 0, nil
	}

	// provider_reputation.provider_id has a FK to providers(id) with NO
	// ON DELETE CASCADE — delete the reputation rows FIRST or the providers
	// delete fails. usage / provider_earnings / provider_sessions hold
	// money/uptime history and have no FK; they are intentionally preserved.
	if _, err := tx.Exec(ctx,
		`DELETE FROM provider_reputation WHERE provider_id = ANY($1)`, ids,
	); err != nil {
		return 0, fmt.Errorf("store: delete provider reputation: %w", err)
	}

	tag, err := tx.Exec(ctx,
		`DELETE FROM providers WHERE id = ANY($1) AND account_id = $2`,
		ids, ownerAccountID,
	)
	if err != nil {
		return 0, fmt.Errorf("store: delete providers: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("store: delete providers commit: %w", err)
	}
	return int(tag.RowsAffected()), nil
}

func (s *PostgresStore) UpsertReputation(ctx context.Context, providerID string, rep store.ReputationRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	return upsertReputationRecord(ctx, s.pool, providerID, rep)
}

func upsertReputationRecord(ctx context.Context, db providerRecordDB, providerID string, rep store.ReputationRecord) error {
	_, err := db.Exec(ctx,
		`INSERT INTO provider_reputation (
			provider_id, total_jobs, successful_jobs, failed_jobs,
			total_uptime_seconds, avg_response_time_ms,
			challenges_passed, challenges_failed, updated_at
		) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
		ON CONFLICT (provider_id) DO UPDATE SET
			total_jobs = $2, successful_jobs = $3, failed_jobs = $4,
			total_uptime_seconds = $5, avg_response_time_ms = $6,
			challenges_passed = $7, challenges_failed = $8,
			updated_at = NOW()`,
		providerID, rep.TotalJobs, rep.SuccessfulJobs, rep.FailedJobs,
		rep.TotalUptimeSeconds, rep.AvgResponseTimeMs,
		rep.ChallengesPassed, rep.ChallengesFailed,
	)
	if err != nil {
		return fmt.Errorf("store: upsert reputation: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetReputation(ctx context.Context, providerID string) (*store.ReputationRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var rep store.ReputationRecord
	err := s.pool.QueryRow(ctx,
		`SELECT total_jobs, successful_jobs, failed_jobs,
			total_uptime_seconds, avg_response_time_ms,
			challenges_passed, challenges_failed
		 FROM provider_reputation WHERE provider_id = $1`, providerID,
	).Scan(
		&rep.TotalJobs, &rep.SuccessfulJobs, &rep.FailedJobs,
		&rep.TotalUptimeSeconds, &rep.AvgResponseTimeMs,
		&rep.ChallengesPassed, &rep.ChallengesFailed,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("store: reputation not found: %w", store.ErrNotFound)
	}
	if err != nil {
		return nil, fmt.Errorf("store: read reputation: %w", err)
	}
	return &rep, nil
}
