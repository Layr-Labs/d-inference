package postgres

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) SettleMachineFloorDraw(ctx context.Context, machine string, draw *store.ProviderFloorDraw) (bool, error) {
	if machine == "" || draw == nil || draw.AccountID == "" || draw.EpochID == "" {
		return false, errors.New("invalid_machine_floor_draw")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		return false, err
	}
	credited, err := settleMachineFloorDraw(ctx, tx, machine, draw)
	if err != nil {
		return false, err
	}
	if err = tx.Commit(ctx); err != nil {
		return false, err
	}
	return credited, nil
}

func settleMachineFloorDraw(ctx context.Context, tx pgx.Tx, machine string, draw *store.ProviderFloorDraw) (bool, error) {
	resolved, already, err := resolveMachineFloorDraw(ctx, tx, machine, draw)
	if err != nil || already {
		return false, err
	}
	return settleProviderFloorDraw(ctx, tx, &resolved)
}

func resolveMachineFloorDraw(ctx context.Context, tx pgx.Tx, machine string, draw *store.ProviderFloorDraw) (store.ProviderFloorDraw, bool, error) {
	var canonical string
	err := tx.QueryRow(ctx, `WITH RECURSIVE chain AS (
	 SELECT id,merged_into,assurance,0 AS depth FROM darkbloom_machines WHERE id=$1
	 UNION ALL SELECT m.id,m.merged_into,m.assurance,c.depth+1 FROM darkbloom_machines m JOIN chain c ON c.merged_into=m.id WHERE c.depth<100)
	 SELECT id FROM chain WHERE merged_into IS NULL AND assurance<>'provisional'
	 AND EXISTS(SELECT 1 FROM darkbloom_machine_sessions s WHERE s.machine_id=chain.id AND s.account_id=$2)`, machine, draw.AccountID).Scan(&canonical)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
	}
	if err != nil {
		return store.ProviderFloorDraw{}, false, err
	}
	var alreadySettled bool
	err = tx.QueryRow(ctx, `WITH RECURSIVE ancestors AS (
	 SELECT id,0 AS depth FROM darkbloom_machines WHERE id=$1
	 UNION ALL SELECT m.id,a.depth+1 FROM darkbloom_machines m JOIN ancestors a ON m.merged_into=a.id WHERE a.depth<100)
	 SELECT EXISTS(SELECT 1 FROM provider_floor_draws d WHERE d.epoch_id=$2 AND (
	 d.provider_key IN (SELECT 'machine:'||id FROM ancestors)
	 OR d.provider_key IN (SELECT p.provider_key FROM provider_sessions p JOIN darkbloom_machine_sessions s ON s.session_id=p.session_id WHERE s.machine_id=$1 AND p.provider_key<>'')))`, canonical, draw.EpochID).Scan(&alreadySettled)
	if err != nil {
		return store.ProviderFloorDraw{}, false, err
	}
	if alreadySettled {
		copy := *draw
		copy.ProviderKey = store.MachineFloorKey(canonical)
		return copy, true, nil
	}
	copy := *draw
	copy.ProviderKey = store.MachineFloorKey(canonical)
	return copy, false, nil
}

// resolveSessionFloorDraw resolves a session's draw under the inventory merge
// barrier before any raw-key credit: a legacy candidate may become canonically
// associated while waiting for the epoch lock, and a canonical-first
// settlement must not be paid a second time.
func resolveSessionFloorDraw(ctx context.Context, tx pgx.Tx, sessionID string, draw *store.ProviderFloorDraw) (store.ProviderFloorDraw, bool, error) {
	var account, machine, assurance string
	err := tx.QueryRow(ctx, `SELECT s.account_id,s.machine_id,m.assurance FROM darkbloom_machine_sessions s JOIN darkbloom_machines m ON m.id=s.machine_id WHERE s.session_id=$1`, sessionID).Scan(&account, &machine, &assurance)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return store.ProviderFloorDraw{}, false, err
	}
	if err == nil && account != "" && account != draw.AccountID {
		return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
	}
	if machine != "" && assurance != "provisional" {
		return resolveMachineFloorDraw(ctx, tx, machine, draw)
	}
	// A new session's inventory may lag its authenticated endpoint-key proof.
	// Reuse only a unique, same-account durable association for that key.
	var machines []string
	err = tx.QueryRow(ctx, `SELECT ARRAY(SELECT DISTINCT s.machine_id FROM provider_sessions p
	 JOIN darkbloom_machine_sessions s ON s.session_id=p.session_id AND s.account_id=$2
	 JOIN darkbloom_machines m ON m.id=s.machine_id AND m.merged_into IS NULL AND m.assurance<>'provisional'
	 WHERE p.provider_key=$1 AND p.provider_key<>'' AND p.account_id=$2 LIMIT 2)`, draw.ProviderKey, draw.AccountID).Scan(&machines)
	if err != nil {
		return store.ProviderFloorDraw{}, false, err
	}
	if len(machines) > 1 {
		return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
	}
	if len(machines) == 1 {
		return resolveMachineFloorDraw(ctx, tx, machines[0], draw)
	}
	var already bool
	err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM provider_floor_draws WHERE provider_key=$1 AND epoch_id=$2)`, draw.ProviderKey, draw.EpochID).Scan(&already)
	return *draw, already, err
}
