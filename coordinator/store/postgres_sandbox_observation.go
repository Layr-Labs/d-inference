package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) ObserveSandboxStopped(ctx context.Context, observation SandboxStoppedObservation) (bool, error) {
	if observation.ObservedAt.IsZero() {
		return false, ErrSandboxInvalidTransition
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	sandbox, err := scanSandboxRecord(tx.QueryRow(ctx, `SELECT `+sandboxSelectColumns+` FROM sandboxes WHERE id=$1 FOR UPDATE`, observation.SandboxID))
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !observation.matches(sandbox) || sandbox.State != SandboxStateReady {
		return false, nil
	}
	// All lifecycle/command admissions lock this same sandbox row first. This
	// check cannot race a new renewal, stop, delete or start admission.
	var pending bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM sandbox_host_operations WHERE sandbox_id=$1 AND state NOT IN ('ready','stopped','deleted','failed'))`, sandbox.ID).Scan(&pending); err != nil {
		return false, err
	}
	if pending {
		return false, nil
	}
	if _, err := tx.Exec(ctx, `UPDATE sandboxes SET state=$2,error_code='',updated_at=GREATEST(updated_at,$3) WHERE id=$1`, sandbox.ID, SandboxStateStopped, observation.ObservedAt); err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, err
	}
	return true, nil
}
