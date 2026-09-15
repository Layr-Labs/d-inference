package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) startAppAttestMaintenance(ctx context.Context) {
	st, ok := store.As[store.AppAttestMaintenanceStore](s.store)
	if !ok {
		return
	}
	saferun.Go(s.logger, "appAttestMaintenance", func() {
		ticker := time.NewTicker(time.Minute)
		defer ticker.Stop()
		for {
			operation, cancel := context.WithTimeout(ctx, 5*time.Second)
			// Five minutes exceeds the live 90-second exchange and DB budgets.
			reconciled, err := st.ReconcileAppAttestEvidence(operation, time.Now().Add(-5*time.Minute), 100)
			s.ddCount("app_attest.maintenance.interrupted", reconciled, nil)
			if err == nil {
				var queued int64
				queued, err = st.QueueAppAttestReceiptRecovery(operation, 100)
				s.ddCount("app_attest.maintenance.receipt_recovery", queued, nil)
			}
			cancel()
			if err != nil && ctx.Err() == nil {
				s.ddIncr("app_attest.maintenance.failed", nil)
			}
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}
