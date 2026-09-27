package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	inferenceReceiptMaintenanceInterval = time.Hour
	inferenceReceiptPendingStaleAfter   = 24 * time.Hour
	inferenceReceiptMaintenanceTimeout  = 10 * time.Minute
	inferenceReceiptMaintenanceBatch    = store.MaxInferenceReceiptPruneLimit
)

// StartInferenceReceiptMaintenance recovers old pending receipts and removes
// expired rows. It runs once at startup and then hourly, and exits when ctx is
// cancelled.
func (s *Server) StartInferenceReceiptMaintenance(ctx context.Context) {
	if s.store == nil {
		return
	}
	saferun.Go(s.logger, "inference_receipts.maintenance", func() {
		s.runInferenceReceiptMaintenance(ctx, inferenceReceiptMaintenanceInterval)
	})
}

func (s *Server) runInferenceReceiptMaintenance(ctx context.Context, interval time.Duration) {
	s.maintainInferenceReceiptsOnce(ctx, time.Now().UTC())
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			s.maintainInferenceReceiptsOnce(ctx, now.UTC())
		}
	}
}

func (s *Server) maintainInferenceReceiptsOnce(ctx context.Context, now time.Time) {
	if s.store == nil {
		return
	}
	maintenanceCtx, cancel := context.WithTimeout(ctx, inferenceReceiptMaintenanceTimeout)
	defer cancel()

	var interrupted int
	for {
		count, err := s.store.InterruptStaleInferenceReceipts(
			maintenanceCtx,
			now.Add(-inferenceReceiptPendingStaleAfter),
			now,
			inferenceReceiptMaintenanceBatch,
		)
		if err != nil {
			s.logger.Error("inference receipt stale-row recovery failed", "error", err)
			break
		}
		interrupted += count
		if count < inferenceReceiptMaintenanceBatch {
			break
		}
	}
	if interrupted > 0 {
		s.logger.Info("interrupted stale inference receipts", "count", interrupted)
	}

	var deleted int
	for {
		count, err := s.store.PruneInferenceReceipts(maintenanceCtx, now, inferenceReceiptMaintenanceBatch)
		if err != nil {
			s.logger.Error("inference receipt expiry pruning failed", "error", err)
			break
		}
		deleted += count
		if count < inferenceReceiptMaintenanceBatch {
			break
		}
	}
	if deleted > 0 {
		s.logger.Info("pruned expired inference receipts", "count", deleted)
	}
}
