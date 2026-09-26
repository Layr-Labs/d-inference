package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// appAttestRotationWindowCount counts rotations for a scope ($1) since $2,
// including rows stored under machines merged into it, directly or through a
// chain: a row keeps the machine that was canonical when it was recorded, and a
// merge moves only aliases and sessions. The walk uses
// darkbloom_machines_merged_into with CanonicalMachineID's depth bound; an
// account scope has no merged machines.
const appAttestRotationWindowCount = `WITH RECURSIVE family AS (
 SELECT $1::text AS id,0 AS depth
 UNION ALL SELECT m.id,f.depth+1 FROM darkbloom_machines m JOIN family f ON m.merged_into=f.id WHERE f.depth<100)
 SELECT count(*) FROM app_attest_key_rotations WHERE machine_id IN (SELECT id FROM family) AND requested_at>=$2`

func (s *PostgresStore) RecordAppAttestKeyRotation(ctx context.Context, r AppAttestKeyRotation) (bool, error) {
	tag, err := s.pool.Exec(ctx, `INSERT INTO app_attest_key_rotations(key_id,machine_id,account_id,requested_at,failures,reason)
	 VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(key_id) DO NOTHING`, r.KeyID, r.MachineID, r.AccountID, r.RequestedAt, r.Failures, r.Reason)
	return tag.RowsAffected() == 1, err
}

// AdmitAppAttestKeyRotation holds the inventory merge barrier shared, resolves
// the current canonical scope, then locks its rotation budget exclusively.
// ObserveMachine takes that barrier exclusively: no merge can change the
// family between canonical resolution, window counts and insertion. Unrelated
// machines can still admit concurrently. Lock order is always barrier, scope.
func (s *PostgresStore) AdmitAppAttestKeyRotation(ctx context.Context, r AppAttestKeyRotation, limits []AppAttestRotationLimit) (*AppAttestKeyRotation, bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock_shared(9952701)`); err != nil {
		return nil, false, err
	}
	var canonical string
	err = tx.QueryRow(ctx, canonicalMachineIDQuery, r.MachineID).Scan(&canonical)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, false, err
	}
	if canonical != "" {
		r.MachineID = canonical
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "app-attest-key-rotation:"+r.MachineID); err != nil {
		return nil, false, err
	}
	existing := AppAttestKeyRotation{KeyID: r.KeyID}
	err = tx.QueryRow(ctx, `SELECT machine_id,account_id,requested_at,failures,reason FROM app_attest_key_rotations WHERE key_id=$1`, r.KeyID).
		Scan(&existing.MachineID, &existing.AccountID, &existing.RequestedAt, &existing.Failures, &existing.Reason)
	if err == nil {
		return &existing, false, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, false, err
	}
	for _, limit := range limits {
		var n int
		if err := tx.QueryRow(ctx, appAttestRotationWindowCount, r.MachineID, r.RequestedAt.Add(-limit.Window)).Scan(&n); err != nil {
			return nil, false, err
		}
		if n >= limit.Max {
			return nil, false, nil
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO app_attest_key_rotations(key_id,machine_id,account_id,requested_at,failures,reason)
	 VALUES($1,$2,$3,$4,$5,$6)`, r.KeyID, r.MachineID, r.AccountID, r.RequestedAt, r.Failures, r.Reason); err != nil {
		return nil, false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, false, err
	}
	return nil, true, nil
}

func (s *PostgresStore) CountAppAttestKeyRotations(ctx context.Context, machineID string, since time.Time) (int, error) {
	canonical, err := s.CanonicalMachineID(ctx, machineID)
	if err != nil {
		return 0, err
	}
	if canonical != "" {
		machineID = canonical
	}
	var n int
	err = s.pool.QueryRow(ctx, appAttestRotationWindowCount, machineID, since).Scan(&n)
	return n, err
}

func (s *PostgresStore) GetAppAttestKeyRotation(ctx context.Context, keyID string) (*AppAttestKeyRotation, error) {
	r := AppAttestKeyRotation{KeyID: keyID}
	err := s.pool.QueryRow(ctx, `SELECT machine_id,account_id,requested_at,failures,reason FROM app_attest_key_rotations WHERE key_id=$1`, keyID).
		Scan(&r.MachineID, &r.AccountID, &r.RequestedAt, &r.Failures, &r.Reason)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &r, nil
}

// Uses app_attest_evidence_key(key_id,received_at DESC); the LIMIT bounds the
// scan for a key that keeps failing.
func (s *PostgresStore) CountAppAttestRotationFailures(ctx context.Context, keyID string, since time.Time) (int, error) {
	var n int
	err := s.pool.QueryRow(ctx, `SELECT count(*) FROM (
	 SELECT 1 FROM app_attest_evidence
	 WHERE key_id=$1 AND received_at>=$2 AND action='assertion' AND outcome='apple_error' AND context->>'key_id'=$1
	 AND COALESCE(context->>'apple_error_source','')<>'proof_oversize'
	 AND (COALESCE(jsonb_typeof(context->'apple_error'),'null')='null'
	  OR (context->'apple_error'->>'domain'='devicecheck' AND context->'apple_error'->>'code' IN ('0','2')))
	 ORDER BY received_at DESC LIMIT $3) eligible`, keyID, since, AppAttestRotationCountCap).Scan(&n)
	return n, err
}

// A session with a failure since T was seen at or after T, so sessions come
// from darkbloom_machine_sessions_machine(machine_id,last_seen DESC), or from
// darkbloom_machine_sessions_seen(last_seen DESC) for the account fallback.
// Each session's evidence uses app_attest_evidence_session(session_id,
// received_at DESC). The LIMIT bounds the result.
func (s *PostgresStore) AppAttestEnrollmentInvalidKeyFailureTimes(ctx context.Context, machineID, accountID string, since time.Time) ([]time.Time, error) {
	scope, value := `m.machine_id=$1`, machineID
	if machineID == "" {
		if accountID == "" {
			return nil, nil
		}
		scope, value = `m.account_id=$1`, accountID
	}
	rows, err := s.pool.Query(ctx, `SELECT e.received_at FROM darkbloom_machine_sessions m
	 JOIN app_attest_evidence e ON e.session_id=m.session_id
	 WHERE `+scope+` AND m.last_seen>=$2
	 AND e.received_at>=$2 AND e.action='attestation' AND e.outcome='apple_invalid_key'
	 ORDER BY e.received_at DESC LIMIT $3`, value, since, AppAttestRotationCountCap)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var times []time.Time
	for rows.Next() {
		var at time.Time
		if err := rows.Scan(&at); err != nil {
			return nil, err
		}
		times = append(times, at)
	}
	return times, rows.Err()
}
