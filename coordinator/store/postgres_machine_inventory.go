package store

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) ObserveMachine(ctx context.Context, o MachineObservation) (MachineIdentity, error) {
	var result MachineIdentity
	if o.SessionID == "" || o.At.IsZero() {
		return result, errors.New("invalid_machine_observation")
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return result, err
	}
	defer tx.Rollback(ctx)
	// A short DB transaction serializes alias creation/merges across processes.
	// It runs on the inventory worker, never under a provider lock or WS reader.
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		return result, err
	}
	var existing, account string
	err = tx.QueryRow(ctx, `SELECT machine_id,account_id FROM darkbloom_machine_sessions WHERE session_id=$1`, o.SessionID).Scan(&existing, &account)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return result, err
	}
	if existing != "" && o.Source == "historical_registration" {
		result.ID = existing
		err = tx.QueryRow(ctx, `SELECT assurance FROM darkbloom_machines WHERE id=$1`, existing).Scan(&result.Assurance)
		if err != nil {
			return result, err
		}
		return result, tx.Commit(ctx)
	}
	if existing != "" && account != o.AccountID {
		return result, errors.New("machine_session_owner_conflict")
	}
	var candidates []string
	for _, a := range o.aliases() {
		var id string
		err = tx.QueryRow(ctx, `SELECT machine_id FROM darkbloom_machine_aliases WHERE kind=$1 AND scope=$2 AND digest=$3`, a.Kind, a.Scope, a.Digest).Scan(&id)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return result, err
		}
		if id != "" {
			candidates = append(candidates, id)
		}
	}
	if existing != "" {
		candidates = append(candidates, existing)
	}
	if len(candidates) > 0 {
		result.ID = candidates[0]
	} else {
		result.ID = uuid.NewString()
	}
	result.Assurance = o.assurance()
	_, err = tx.Exec(ctx, `INSERT INTO darkbloom_machines(id,assurance,first_seen,last_seen) VALUES($1,$2,$3,$3) ON CONFLICT(id) DO UPDATE SET last_seen=GREATEST(darkbloom_machines.last_seen,$3)`, result.ID, result.Assurance, o.At)
	if err != nil {
		return result, err
	}
	var oldAssurance string
	if err = tx.QueryRow(ctx, `SELECT assurance FROM darkbloom_machines WHERE id=$1`, result.ID).Scan(&oldAssurance); err != nil {
		return result, err
	}
	result.Assurance = strongerAssurance(oldAssurance, result.Assurance)
	for _, old := range candidates {
		if old == result.ID {
			continue
		}
		// Multiple aliases can name the same source. Preserve the first merge.
		tag, e := tx.Exec(ctx, `UPDATE darkbloom_machines SET merged_into=$2 WHERE id=$1 AND merged_into IS NULL`, old, result.ID)
		if e != nil {
			return result, e
		}
		if tag.RowsAffected() == 0 {
			continue
		}
		for _, q := range []string{
			`UPDATE darkbloom_machine_aliases SET machine_id=$2 WHERE machine_id=$1`,
			`UPDATE darkbloom_machine_sessions SET machine_id=$2 WHERE machine_id=$1`,
			`UPDATE darkbloom_machines SET first_seen=LEAST(first_seen,(SELECT first_seen FROM darkbloom_machines WHERE id=$1)) WHERE id=$2`,
		} {
			if _, err = tx.Exec(ctx, q, old, result.ID); err != nil {
				return result, err
			}
		}
		if _, err = tx.Exec(ctx, `INSERT INTO darkbloom_machine_merges VALUES($1,$2,$3,$4,'verified_alias_association')`, old, result.ID, o.SessionID, o.At); err != nil {
			return result, err
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE darkbloom_machines SET assurance=$2 WHERE id=$1`, result.ID, result.Assurance); err != nil {
		return result, err
	}
	for _, a := range o.aliases() {
		if _, err = tx.Exec(ctx, `INSERT INTO darkbloom_machine_aliases VALUES($1,$2,$3,$4,$5) ON CONFLICT(kind,scope,digest) DO UPDATE SET verified_at=$5`, a.Kind, a.Scope, a.Digest, result.ID, o.At); err != nil {
			return result, err
		}
	}
	raw, err := json.Marshal(o)
	if err != nil {
		return result, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO darkbloom_machine_sessions(session_id,machine_id,original_machine_id,account_id,first_seen,last_seen,disconnected_at,observation)
	 VALUES($1,$2,$2,$3,$4,$4,CASE WHEN $5 THEN $4::timestamptz END,$6)
	 ON CONFLICT(session_id) DO UPDATE SET machine_id=$2,last_seen=GREATEST(darkbloom_machine_sessions.last_seen,$4),
	 disconnected_at=CASE WHEN $5 THEN $4 ELSE darkbloom_machine_sessions.disconnected_at END,observation=$6`, o.SessionID, result.ID, o.AccountID, o.At, o.Disconnected, raw)
	if err != nil {
		return result, err
	}
	// Only changed observations are appended. Heartbeats update liveness above.
	_, err = tx.Exec(ctx, `INSERT INTO darkbloom_machine_observations SELECT $1,$2,$3 WHERE NOT EXISTS
	 (SELECT 1 FROM (SELECT observation FROM darkbloom_machine_observations WHERE session_id=$1 ORDER BY observed_at DESC LIMIT 1) prior
	 WHERE prior.observation - 'observed_at' = $3::jsonb - 'observed_at') ON CONFLICT DO NOTHING`, o.SessionID, o.At, raw)
	if err != nil {
		return result, err
	}
	return result, tx.Commit(ctx)
}

func (s *PostgresStore) RecordAppAttestEvent(ctx context.Context, e AppAttestEvent) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO app_attest_shadow_events VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(id) DO NOTHING`, e.ID, e.SessionID, e.At, e.Stage, e.Outcome, e.Fields)
	return err
}
