package store

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// --- Provider Fleet Persistence ---

func marshalProviderLocation(loc *ProviderLocation) json.RawMessage {
	if loc == nil {
		return nil
	}
	b, err := json.Marshal(loc)
	if err != nil {
		return nil
	}
	return b
}

func unmarshalProviderLocation(raw []byte) *ProviderLocation {
	if len(raw) == 0 {
		return nil
	}
	var loc ProviderLocation
	if err := json.Unmarshal(raw, &loc); err != nil {
		return nil
	}
	return &loc
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
			registered_at, last_seen, public_key
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7,
			$8, $9, $10,
			$11, $12, $13,
			$14, $15, $16, $17,
			$18, $19, $20,
			$21, $22, $23, $24,
			$25, $26, $27
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
			last_seen = $26, public_key = $27`,
		p.ID, p.Hardware, p.Models, p.Backend,
		marshalProviderLocation(p.Location),
		p.TrustLevel, p.Attested,
		p.AttestationResult, p.SEPublicKey, p.SerialNumber,
		p.MDAVerified, p.MDACertChain, p.ACMEVerified,
		p.Version, p.RuntimeVerified, p.PythonHash, p.RuntimeHash,
		p.LastChallengeVerified, p.FailedChallenges, p.AccountID,
		p.LifetimeRequestsServed, p.LifetimeTokensGenerated,
		p.LastSessionRequestsServed, p.LastSessionTokensGenerated,
		p.RegisteredAt, p.LastSeen, p.PublicKey,
	)
	if err != nil {
		return fmt.Errorf("store: upsert provider: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetProviderRecord(ctx context.Context, id string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var p ProviderRecord
	var locationRaw []byte
	err := s.pool.QueryRow(ctx,
		`SELECT id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen, public_key
		 FROM providers WHERE id = $1`, id,
	).Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&locationRaw,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
	)
	if err != nil {
		return nil, fmt.Errorf("store: provider not found: %w", err)
	}
	p.Location = unmarshalProviderLocation(locationRaw)
	return &p, nil
}

func (s *PostgresStore) GetProviderBySerial(ctx context.Context, serial string) (*ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var p ProviderRecord
	var locationRaw []byte
	err := s.pool.QueryRow(ctx,
		`SELECT id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen, public_key
		 FROM providers WHERE serial_number = $1 AND serial_number != ''
		 ORDER BY last_seen DESC LIMIT 1`, serial,
	).Scan(
		&p.ID, &p.Hardware, &p.Models, &p.Backend,
		&locationRaw,
		&p.TrustLevel, &p.Attested,
		&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
		&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
		&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
		&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
		&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
		&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
		&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
	)
	if err != nil {
		return nil, fmt.Errorf("store: provider with serial not found: %w", err)
	}
	p.Location = unmarshalProviderLocation(locationRaw)
	return &p, nil
}

func (s *PostgresStore) ListProviderRecords(ctx context.Context) ([]ProviderRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen, public_key
		 FROM providers ORDER BY last_seen DESC`,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list providers: %w", err)
	}
	defer rows.Close()

	var records []ProviderRecord
	for rows.Next() {
		var p ProviderRecord
		var locationRaw []byte
		if err := rows.Scan(
			&p.ID, &p.Hardware, &p.Models, &p.Backend,
			&locationRaw,
			&p.TrustLevel, &p.Attested,
			&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
			&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
			&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
			&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
			&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
			&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
			&p.RegisteredAt, &p.LastSeen, &p.PublicKey,
		); err != nil {
			continue
		}
		p.Location = unmarshalProviderLocation(locationRaw)
		records = append(records, p)
	}
	if records == nil {
		return []ProviderRecord{}, nil
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
		 id, hardware, models, backend, location, trust_level, attested,
			attestation_result, se_public_key, serial_number,
			mda_verified, mda_cert_chain, acme_verified,
			version, runtime_verified, python_hash, runtime_hash,
			last_challenge_verified, failed_challenges, account_id,
			lifetime_requests_served, lifetime_tokens_generated,
			last_session_requests_served, last_session_tokens_generated,
			registered_at, last_seen, public_key
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
		var p ProviderRecord
		var locationRaw []byte
		if err := rows.Scan(
			&p.ID, &p.Hardware, &p.Models, &p.Backend,
			&locationRaw,
			&p.TrustLevel, &p.Attested,
			&p.AttestationResult, &p.SEPublicKey, &p.SerialNumber,
			&p.MDAVerified, &p.MDACertChain, &p.ACMEVerified,
			&p.Version, &p.RuntimeVerified, &p.PythonHash, &p.RuntimeHash,
			&p.LastChallengeVerified, &p.FailedChallenges, &p.AccountID,
			&p.LifetimeRequestsServed, &p.LifetimeTokensGenerated,
			&p.LastSessionRequestsServed, &p.LastSessionTokensGenerated,
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

// --- Provider Reputation Persistence ---

func (s *PostgresStore) UpsertReputation(ctx context.Context, providerID string, rep ReputationRecord) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
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

func (s *PostgresStore) GetReputation(ctx context.Context, providerID string) (*ReputationRecord, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	var rep ReputationRecord
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
	if err != nil {
		return nil, fmt.Errorf("store: reputation not found: %w", err)
	}
	return &rep, nil
}

// --- Provider Log Reports ---

const maxLogReportSize = 10 << 20 // 10 MB

func (s *PostgresStore) StoreLogReport(serialNumber, providerID, accountID string, logData []byte) error {
	if len(logData) > maxLogReportSize {
		logData = logData[:maxLogReportSize]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_log_reports (serial_number, provider_id, account_id, log_data, log_size_bytes)
		 VALUES ($1, $2, $3, $4, $5)`,
		serialNumber, providerID, accountID, logData, int64(len(logData)),
	)
	if err != nil {
		return fmt.Errorf("store: insert log report: %w", err)
	}
	return nil
}

func (s *PostgresStore) GetLogReports(serialNumber string, limit int) ([]LogReport, error) {
	if limit <= 0 || limit > 100 {
		limit = 10
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT id, serial_number, provider_id, account_id, log_size_bytes, created_at
		 FROM provider_log_reports
		 WHERE serial_number = $1
		 ORDER BY created_at DESC
		 LIMIT $2`,
		serialNumber, limit,
	)
	if err != nil {
		return nil, fmt.Errorf("store: list log reports: %w", err)
	}
	defer rows.Close()

	var reports []LogReport
	for rows.Next() {
		var r LogReport
		if err := rows.Scan(&r.ID, &r.SerialNumber, &r.ProviderID, &r.AccountID, &r.LogSizeBytes, &r.CreatedAt); err != nil {
			continue
		}
		reports = append(reports, r)
	}
	if reports == nil {
		return []LogReport{}, nil
	}
	return reports, nil
}

func (s *PostgresStore) GetLogReport(id int64) (*LogReport, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var r LogReport
	err := s.pool.QueryRow(ctx,
		`SELECT id, serial_number, provider_id, account_id, log_data, log_size_bytes, created_at
		 FROM provider_log_reports WHERE id = $1`, id,
	).Scan(&r.ID, &r.SerialNumber, &r.ProviderID, &r.AccountID, &r.LogData, &r.LogSizeBytes, &r.CreatedAt)
	if err != nil {
		return nil, fmt.Errorf("store: log report %d not found: %w", id, err)
	}
	return &r, nil
}

// OpenProviderSession records the start of a provider connection. Idempotent:
// ON CONFLICT DO NOTHING so a duplicate register, or an open that races behind a
// close (fast connect→disconnect), never creates a second or reopened row.
func (s *PostgresStore) OpenProviderSession(ctx context.Context, sessionID, serial, accountID string) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_sessions (session_id, serial_number, account_id)
		 VALUES ($1, $2, $3)
		 ON CONFLICT (session_id) DO NOTHING`,
		sessionID, serial, accountID,
	)
	if err != nil {
		return fmt.Errorf("store: open provider session: %w", err)
	}
	return nil
}

// TouchProviderSession updates the open session's last_seen and backfills
// serial/account if they were unknown at open time.
func (s *PostgresStore) TouchProviderSession(ctx context.Context, sessionID, serial, accountID string, lastSeen time.Time) error {
	_, err := s.pool.Exec(ctx,
		`UPDATE provider_sessions
		    SET last_seen = $2,
		        serial_number = CASE WHEN serial_number = '' THEN $3 ELSE serial_number END,
		        account_id    = CASE WHEN account_id = ''    THEN $4 ELSE account_id    END
		  WHERE session_id = $1 AND disconnected_at IS NULL`,
		sessionID, lastSeen, serial, accountID,
	)
	if err != nil {
		return fmt.Errorf("store: touch provider session: %w", err)
	}
	return nil
}

// CloseProviderSession marks the session for sessionID as ended. Implemented as
// an upsert so it is correct regardless of whether the async OpenProviderSession
// has landed yet: if the row is missing (close raced ahead of open on a fast
// connect→disconnect) it inserts an already-closed row; if open, it closes it;
// if already closed, it leaves the original disconnect timestamp/reason intact.
func (s *PostgresStore) CloseProviderSession(ctx context.Context, sessionID, reason string, when time.Time) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO provider_sessions (session_id, connected_at, last_seen, disconnected_at, disconnect_reason)
		 VALUES ($1, $3, $3, $3, $2)
		 ON CONFLICT (session_id) DO UPDATE
		    SET disconnected_at = COALESCE(provider_sessions.disconnected_at, EXCLUDED.disconnected_at),
		        disconnect_reason = CASE WHEN provider_sessions.disconnected_at IS NULL
		                                 THEN EXCLUDED.disconnect_reason
		                                 ELSE provider_sessions.disconnect_reason END`,
		sessionID, reason, when,
	)
	if err != nil {
		return fmt.Errorf("store: close provider session: %w", err)
	}
	return nil
}

// CloseOpenProviderSessions closes open sessions whose last heartbeat predates
// staleBefore (orphaned by a prior coordinator process), setting disconnected_at
// to the last heartbeat seen. The last_seen < staleBefore fence prevents a
// blue-green deploy from truncating a session still live (and being touched) on
// the old instance over the shared DB — its last_seen stays fresh.
//
// Note: crash-path disconnected_at granularity is bounded by how often last_seen
// advances. Heartbeats touch it (TouchProviderSession), so the recorded
// disconnect can lag the true last-seen by at most the heartbeat interval.
func (s *PostgresStore) CloseOpenProviderSessions(ctx context.Context, staleBefore time.Time) (int, error) {
	tag, err := s.pool.Exec(ctx,
		`UPDATE provider_sessions
		    SET disconnected_at = last_seen, disconnect_reason = 'coordinator_restart'
		  WHERE disconnected_at IS NULL AND last_seen < $1`,
		staleBefore,
	)
	if err != nil {
		return 0, fmt.Errorf("store: close open provider sessions: %w", err)
	}
	return int(tag.RowsAffected()), nil
}
