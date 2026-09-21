package store

import (
	"context"
	"errors"
	"strings"
)

func (s *MemoryStore) SettleProviderFloorDrawBatch(ctx context.Context, items []FloorDrawBatchItem, authorize func(int) bool) (FloorDrawBatchResult, error) {
	if err := validateFloorDrawBatch(items, authorize); err != nil {
		return FloorDrawBatchResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return FloorDrawBatchResult{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	resolved := make([]ProviderFloorDraw, len(items))
	seen := make(map[string]int, len(items))
	for i, item := range items {
		if err := ctx.Err(); err != nil {
			return FloorDrawBatchResult{}, err
		}
		var already bool
		var err error
		if item.MachineID != "" {
			resolved[i], already, err = s.resolveMachineFloorDrawLocked(item.MachineID, &item.Draw)
		} else {
			resolved[i], already, err = s.resolveSessionFloorDrawLocked(item.SessionID, &item.Draw)
		}
		if errors.Is(err, ErrMachineContinuityUnverified) {
			return floorDrawBatchRejected(i, FloorDrawIdentity), nil
		}
		if err != nil {
			return FloorDrawBatchResult{}, err
		}
		if already {
			return floorDrawBatchRejected(i, FloorDrawAlreadyPaid), nil
		}
		if prior, exists := seen[resolved[i].ProviderKey]; exists {
			machine := ""
			if strings.HasPrefix(resolved[i].ProviderKey, "machine:") {
				machine = strings.TrimPrefix(resolved[i].ProviderKey, "machine:")
			}
			return floorDrawBatchDuplicate(i, prior, machine), nil
		}
		seen[resolved[i].ProviderKey] = i
		if !authorize(i) {
			return floorDrawBatchRejected(i, FloorDrawUnauthorized), nil
		}
	}
	// Recheck earlier candidates too: another candidate's check may race with
	// revocation. No in-memory money state changes until the complete plan is
	// accepted, and all writes remain under the inventory/ledger mutex.
	for i := range items {
		if !authorize(i) {
			return floorDrawBatchRejected(i, FloorDrawUnauthorized), nil
		}
	}
	if err := ctx.Err(); err != nil {
		return FloorDrawBatchResult{}, err
	}
	for i := range resolved {
		// Inputs, unique keys and all idempotency guards were checked above;
		// the locked helper cannot fail or encounter a competing insertion here.
		_, _ = s.settleProviderFloorDrawLocked(&resolved[i])
	}
	return FloorDrawBatchResult{Committed: true}, nil
}
