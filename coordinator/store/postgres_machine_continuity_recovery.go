package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// RecoverLiveAppAttestMachineSession repairs the precise startup-backfill race
// where a historical tombstone was inserted before the live inventory capture.
// It never reopens an observed live disconnect or a provider-session terminal.
func (s *PostgresStore) RecoverLiveAppAttestMachineSession(ctx context.Context, sessionID, account, key string, now time.Time) (bool, error) {
	if sessionID == "" || account == "" || key == "" || now.IsZero() {
		return false, nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	alias := appAttestMachineAlias(account, key)
	var machineID string
	err = tx.QueryRow(ctx, `SELECT m.machine_id
	 FROM darkbloom_machine_sessions m
	 JOIN provider_sessions p ON p.session_id=m.session_id AND p.account_id=$2
	 JOIN app_attest_shadow_keys k ON k.key_id=$3 AND k.evidence->>'account_id'=$2
	 WHERE m.session_id=$1 AND m.account_id=$2 AND m.disconnected_at IS NOT NULL
	 AND m.observation->>'source'='historical_registration'
	 AND m.observation->>'disconnect_reason'='observed_disconnect'
	 AND p.disconnected_at IS NULL AND p.last_seen > m.disconnected_at
	 AND p.last_seen >= $4::timestamptz - interval '2 minutes'
	 AND NOT EXISTS(SELECT 1 FROM app_attest_key_revocations r WHERE r.key_id=$3)
	 AND NOT EXISTS(SELECT 1 FROM darkbloom_machine_aliases a
	   WHERE a.kind='app_attest' AND a.scope=$2 AND a.digest=$5 AND a.machine_id<>m.machine_id)
	 FOR UPDATE OF m,p`, sessionID, account, key, now, alias.Digest).Scan(&machineID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	_, err = tx.Exec(ctx, `UPDATE darkbloom_machine_sessions
	 SET disconnected_at=NULL,last_seen=GREATEST(last_seen,$2),
	 observation=observation || jsonb_build_object('disconnected',false,'disconnect_reason','','observed_at',$2,'source','live_assertion_recovery')
	 WHERE session_id=$1`, sessionID, now)
	if err != nil {
		return false, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO darkbloom_machine_observations(session_id,observed_at,observation)
	 SELECT session_id,$2,observation FROM darkbloom_machine_sessions WHERE session_id=$1 ON CONFLICT DO NOTHING`, sessionID, now)
	if err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, err
	}
	return true, nil
}
