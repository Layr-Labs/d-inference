package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

func (s *Server) startMachineInventoryBackfill(ctx context.Context) {
	st, ok := store.As[store.MachineInventoryBackfillStore](s.store)
	if !ok {
		return
	}
	saferun.Go(s.logger, "machineInventoryBackfill", func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				operation, cancel := context.WithTimeout(ctx, 4*time.Second)
				n, err := st.BackfillMachineInventory(operation, 100)
				cancel()
				if err != nil {
					s.ddIncr("app_attest.inventory.backfill_failed", nil)
					continue
				}
				if n == 0 {
					return
				}
			}
		}
	})
}
