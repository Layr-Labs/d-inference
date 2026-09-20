package store

import (
	"context"
	"errors"
	"strings"
)

func (s *PostgresStore) SettleProviderFloorDrawBatch(ctx context.Context, items []FloorDrawBatchItem, authorize func(int) bool) (FloorDrawBatchResult, error) {
	if err := validateFloorDrawBatch(items, authorize); err != nil {
		return FloorDrawBatchResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return FloorDrawBatchResult{}, err
	}
	if len(items) == 0 {
		return FloorDrawBatchResult{Committed: true}, nil
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return FloorDrawBatchResult{}, err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(9952701)`); err != nil {
		return FloorDrawBatchResult{}, err
	}
	seen := make(map[string]int, len(items))
	for i, item := range items {
		var resolved ProviderFloorDraw
		var already bool
		if item.MachineID != "" {
			resolved, already, err = resolveMachineFloorDraw(ctx, tx, item.MachineID, &item.Draw)
		} else {
			resolved, already, err = resolveSessionFloorDraw(ctx, tx, item.SessionID, &item.Draw)
		}
		if errors.Is(err, ErrMachineContinuityUnverified) {
			return floorDrawBatchRejected(i, FloorDrawIdentity), nil
		}
		if err != nil {
			return FloorDrawBatchResult{}, err
		}
		if prior, exists := seen[resolved.ProviderKey]; exists {
			machine := ""
			if strings.HasPrefix(resolved.ProviderKey, "machine:") {
				machine = strings.TrimPrefix(resolved.ProviderKey, "machine:")
			}
			return floorDrawBatchDuplicate(i, prior, machine), nil
		}
		if already {
			return floorDrawBatchRejected(i, FloorDrawAlreadyPaid), nil
		}
		seen[resolved.ProviderKey] = i
		if !authorize(i) {
			return floorDrawBatchRejected(i, FloorDrawUnauthorized), nil
		}
		credited, err := settleProviderFloorDraw(ctx, tx, &resolved)
		if err != nil {
			return FloorDrawBatchResult{}, err
		}
		if !credited {
			return floorDrawBatchRejected(i, FloorDrawAlreadyPaid), nil
		}
	}
	// Every partial/full/waitlisted row is still uncommitted. An authorization
	// lost after an earlier INSERT rolls back that row as well, so a retry can
	// redistribute the whole unspent pool without modifying frozen old draws.
	for i := range items {
		if !authorize(i) {
			return floorDrawBatchRejected(i, FloorDrawUnauthorized), nil
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return FloorDrawBatchResult{}, err
	}
	return FloorDrawBatchResult{Committed: true}, nil
}
