package postgres

import (
	"context"
	"errors"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

var _ store.FloorDrawBatchStore = (*PostgresStore)(nil)

func (s *PostgresStore) SettleProviderFloorDrawBatch(ctx context.Context, items []store.FloorDrawBatchItem, authorize func(int) bool) (store.FloorDrawBatchResult, error) {
	if err := shared.ValidateFloorDrawBatch(items, authorize); err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	if len(items) == 0 {
		return store.FloorDrawBatchResult{Committed: true}, nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	seen := make(map[string]int, len(items))
	for i, item := range items {
		var resolved store.ProviderFloorDraw
		var already bool
		if item.MachineID != "" {
			resolved, already, err = resolveMachineFloorDraw(ctx, tx, item.MachineID, &item.Draw)
		} else {
			resolved, already, err = resolveSessionFloorDraw(ctx, tx, item.SessionID, &item.Draw)
		}
		if errors.Is(err, store.ErrMachineContinuityUnverified) {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawIdentity), nil
		}
		if err != nil {
			return store.FloorDrawBatchResult{}, err
		}
		if prior, exists := seen[resolved.ProviderKey]; exists {
			machine := ""
			if strings.HasPrefix(resolved.ProviderKey, "machine:") {
				machine = strings.TrimPrefix(resolved.ProviderKey, "machine:")
			}
			return shared.FloorDrawBatchDuplicate(i, prior, machine), nil
		}
		if already {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawAlreadyPaid), nil
		}
		seen[resolved.ProviderKey] = i
		if !authorize(i) {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawUnauthorized), nil
		}
		credited, err := settleProviderFloorDraw(ctx, tx, &resolved)
		if err != nil {
			return store.FloorDrawBatchResult{}, err
		}
		if !credited {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawAlreadyPaid), nil
		}
	}
	// Every partial/full/waitlisted row is still uncommitted. An authorization
	// lost after an earlier INSERT rolls back that row as well, so a retry can
	// redistribute the whole unspent pool without modifying frozen old draws.
	for i := range items {
		if !authorize(i) {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawUnauthorized), nil
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	return store.FloorDrawBatchResult{Committed: true}, nil
}
