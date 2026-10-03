package memory

import (
	"context"
	"errors"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

var _ store.FloorDrawBatchStore = (*MemoryStore)(nil)

func (s *MemoryStore) SettleProviderFloorDrawBatch(ctx context.Context, items []store.FloorDrawBatchItem, authorize func(int) bool) (store.FloorDrawBatchResult, error) {
	if err := shared.ValidateFloorDrawBatch(items, authorize); err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	resolved := make([]store.ProviderFloorDraw, len(items))
	seen := make(map[string]int, len(items))
	for i, item := range items {
		if err := ctx.Err(); err != nil {
			return store.FloorDrawBatchResult{}, err
		}
		var already bool
		var err error
		if item.MachineID != "" {
			resolved[i], already, err = s.resolveMachineFloorDrawLocked(item.MachineID, &item.Draw)
		} else {
			resolved[i], already, err = s.resolveSessionFloorDrawLocked(item.SessionID, &item.Draw)
		}
		if errors.Is(err, store.ErrMachineContinuityUnverified) {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawIdentity), nil
		}
		if err != nil {
			return store.FloorDrawBatchResult{}, err
		}
		if already {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawAlreadyPaid), nil
		}
		if prior, exists := seen[resolved[i].ProviderKey]; exists {
			machine := ""
			if strings.HasPrefix(resolved[i].ProviderKey, "machine:") {
				machine = strings.TrimPrefix(resolved[i].ProviderKey, "machine:")
			}
			return shared.FloorDrawBatchDuplicate(i, prior, machine), nil
		}
		seen[resolved[i].ProviderKey] = i
		if !authorize(i) {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawUnauthorized), nil
		}
	}
	// Recheck earlier candidates too: another candidate's check may race with
	// revocation. No in-memory money state changes until the complete plan is
	// accepted, and all writes remain under the inventory/ledger mutex.
	for i := range items {
		if !authorize(i) {
			return shared.FloorDrawBatchRejected(i, store.FloorDrawUnauthorized), nil
		}
	}
	if err := ctx.Err(); err != nil {
		return store.FloorDrawBatchResult{}, err
	}
	for i := range resolved {
		// Inputs, unique keys and all idempotency guards were checked above;
		// the locked helper cannot fail or encounter a competing insertion here.
		_, _ = s.settleProviderFloorDrawLocked(&resolved[i])
	}
	return store.FloorDrawBatchResult{Committed: true}, nil
}
