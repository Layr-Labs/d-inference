package service

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A failed terminal capture remains discoverable in the durable session table.
// Retry bounded batches throughout the process lifetime, not just at startup.
func (s *Service) startMachineInventoryReconciler(ctx context.Context) {
	st, ok := store.As[store.MachineInventoryReconcileStore](s.store)
	if !ok {
		return
	}
	reconciler := inventory.NewReconciler(st, s.inventorySlots, s.ddIncr, s.ddCount)
	saferun.Go(s.logger, "machineInventoryReconcile", func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			reconciler.Reconcile(ctx)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}
