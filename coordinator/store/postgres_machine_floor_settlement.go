package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) SettleMachineFloorDraw(ctx context.Context, machine string, draw *ProviderFloorDraw) (bool, error) {
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

func settleMachineFloorDraw(ctx context.Context, tx pgx.Tx, machine string, draw *ProviderFloorDraw) (bool, error) {
	var canonical string
	err := tx.QueryRow(ctx, `WITH RECURSIVE chain AS (
	 SELECT id,merged_into,assurance,0 AS depth FROM darkbloom_machines WHERE id=$1
	 UNION ALL SELECT m.id,m.merged_into,m.assurance,c.depth+1 FROM darkbloom_machines m JOIN chain c ON c.merged_into=m.id WHERE c.depth<100)
	 SELECT id FROM chain WHERE merged_into IS NULL AND assurance<>'provisional'
	 AND EXISTS(SELECT 1 FROM darkbloom_machine_sessions s WHERE s.machine_id=chain.id AND s.account_id=$2)`, machine, draw.AccountID).Scan(&canonical)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrMachineContinuityUnverified
	}
	if err != nil {
		return false, err
	}
	var alreadySettled bool
	err = tx.QueryRow(ctx, `WITH RECURSIVE ancestors AS (
	 SELECT id,0 AS depth FROM darkbloom_machines WHERE id=$1
	 UNION ALL SELECT m.id,a.depth+1 FROM darkbloom_machines m JOIN ancestors a ON m.merged_into=a.id WHERE a.depth<100)
	 SELECT EXISTS(SELECT 1 FROM provider_floor_draws d WHERE d.epoch_id=$2 AND (
	 d.provider_key IN (SELECT 'machine:'||id FROM ancestors)
	 OR d.provider_key IN (SELECT p.provider_key FROM provider_sessions p JOIN darkbloom_machine_sessions s ON s.session_id=p.session_id WHERE s.machine_id=$1 AND p.provider_key<>'')))`, canonical, draw.EpochID).Scan(&alreadySettled)
	if err != nil {
		return false, err
	}
	if alreadySettled {
		return false, nil
	}
	copy := *draw
	copy.ProviderKey = MachineFloorKey(canonical)
	return settleProviderFloorDraw(ctx, tx, &copy)
}

// A legacy candidate may become canonically associated while waiting for the
// epoch lock. Resolve again under the inventory merge barrier before any raw
// key credit, so a canonical-first settlement cannot be paid a second time.
func (s *PostgresStore) SettleProviderFloorDrawForSession(ctx context.Context, sessionID string, draw *ProviderFloorDraw) (bool, error) {
	if sessionID == "" || draw == nil || draw.AccountID == "" || draw.ProviderKey == "" || draw.EpochID == "" {
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
	var account, machine, assurance string
	err = tx.QueryRow(ctx, `SELECT s.account_id,s.machine_id,m.assurance FROM darkbloom_machine_sessions s JOIN darkbloom_machines m ON m.id=s.machine_id WHERE s.session_id=$1`, sessionID).Scan(&account, &machine, &assurance)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return false, err
	}
	if err == nil && account != "" && account != draw.AccountID {
		return false, ErrMachineContinuityUnverified
	}
	var credited bool
	if machine != "" && assurance != "provisional" {
		credited, err = settleMachineFloorDraw(ctx, tx, machine, draw)
	} else {
		credited, err = settleProviderFloorDraw(ctx, tx, draw)
	}
	if err != nil {
		return false, err
	}
	if err = tx.Commit(ctx); err != nil {
		return false, err
	}
	return credited, nil
}
