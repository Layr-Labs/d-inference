package service

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const machineInventoryStaleAfter = 5 * time.Minute

// A failed terminal capture remains discoverable in the durable session table.
// Retry bounded batches throughout the process lifetime, not just at startup.
func (s *Service) startMachineInventoryReconciler(ctx context.Context) {
	st, ok := store.As[store.MachineInventoryReconcileStore](s.store)
	if !ok {
		return
	}
	saferun.Go(s.logger, "machineInventoryReconcile", func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			s.reconcileMachineInventory(ctx, st)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}

func (s *Service) reconcileMachineInventory(ctx context.Context, st store.MachineInventoryReconcileStore) {
	operation, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if s.inventorySlots != nil {
		select {
		case s.inventorySlots <- struct{}{}:
			defer func() { <-s.inventorySlots }()
		case <-operation.Done():
			s.ddIncr("app_attest.inventory.reconcile_failed", []string{"reason:busy"})
			return
		}
	}
	if operation.Err() != nil {
		return
	}
	count, err := st.ReconcileMachineInventory(operation, time.Now().UTC().Add(-machineInventoryStaleAfter), 100)
	if err != nil {
		s.ddIncr("app_attest.inventory.reconcile_failed", []string{"reason:storage_error"})
	} else if count > 0 {
		s.ddCount("app_attest.inventory.reconciled", int64(count), nil)
	}
}
