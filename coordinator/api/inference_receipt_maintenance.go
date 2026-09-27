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
// cancelled. It runs whenever the store has the receipt capability, even with
// receipts disabled, so rows written before the feature was switched off still
// expire on schedule.
func (s *Server) StartInferenceReceiptMaintenance(ctx context.Context) {
	if _, ok := s.inferenceReceiptStore(); !ok {
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

// maintainInferenceReceiptsOnce interrupts pending rows older than
// inferenceReceiptPendingStaleAfter — far beyond any request deadline, so only
// rows orphaned by a coordinator restart mid-request — and then prunes expired
// rows. Both loops drain in bounded batches under one overall timeout.
func (s *Server) maintainInferenceReceiptsOnce(ctx context.Context, now time.Time) {
	receiptStore, ok := s.inferenceReceiptStore()
	if !ok {
		return
	}
	maintenanceCtx, cancel := context.WithTimeout(ctx, inferenceReceiptMaintenanceTimeout)
	defer cancel()

	var interrupted int
	for {
		count, err := receiptStore.InterruptStaleInferenceReceipts(
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
		count, err := receiptStore.PruneInferenceReceipts(maintenanceCtx, now, inferenceReceiptMaintenanceBatch)
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
