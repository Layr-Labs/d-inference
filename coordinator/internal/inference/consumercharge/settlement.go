// Package consumercharge reconciles ordinary consumer settlements whose commit
// outcome is unknown. The store result is durable; pending callbacks are not.
package consumercharge

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Settler interface {
	FinalizeConsumerCharge(store.ConsumerChargeSettlement) (store.ConsumerChargeResult, error)
}

type Engine struct {
	pending sync.Map
}

type pendingCharge struct {
	mu       sync.Mutex
	done     bool
	input    store.ConsumerChargeSettlement
	settler  Settler
	complete func(store.ConsumerChargeResult)
}

// Settle owns the reservation even on an ambiguous commit. A timeout must never
// refund a charge that may already have produced a referral reward.
func (e *Engine) Settle(pr *registry.PendingRequest, backend Settler, in store.ConsumerChargeSettlement, complete func(store.ConsumerChargeResult)) (bool, store.ConsumerChargeResult, error) {
	var result store.ConsumerChargeResult
	var err error
	retried := false
	pending := &pendingCharge{input: in, settler: backend, complete: complete}
	pending.mu.Lock()
	defer pending.mu.Unlock()
	owned := false
	finalized, _ := pr.FinalizeReservation(func() error {
		// Claim before the first store call, not just after a failure. A fresh
		// PendingRequest has a separate reservation gate but must not steal
		// this job's callback from its initial settlement or recovery.
		if _, loaded := e.pending.LoadOrStore(in.JobID, pending); loaded {
			return nil
		}
		owned = true
		for attempt := 0; attempt < 3; attempt++ {
			result, err = backend.FinalizeConsumerCharge(in)
			if err == nil {
				break
			}
			retried = true
		}
		return nil
	})
	if !finalized || !owned {
		return false, result, nil
	}
	if err != nil {
		return false, result, err
	}
	pending.done = true
	defer e.pending.Delete(in.JobID)
	// An in-call retry may recover this owner's lost acknowledgement. An
	// already-applied result without a retry is a replay, not fresh work.
	if !result.Applied && !retried {
		return false, result, nil
	}
	complete(result)
	return true, result, nil
}

// Maintain retries each pending charge once, like promotion maintenance. The
// per-charge lock prevents overlapping maintenance passes repeating callbacks.
func (e *Engine) Maintain(ctx context.Context, logger *slog.Logger) {
	e.pending.Range(func(key, value any) bool {
		if ctx.Err() != nil {
			return false
		}
		pending := value.(*pendingCharge)
		pending.mu.Lock()
		defer pending.mu.Unlock()
		if pending.done {
			return true
		}
		result, err := pending.settler.FinalizeConsumerCharge(pending.input)
		if err != nil {
			logger.Error("consumer settlement reconciliation failed", "request_id", pending.input.JobID, "error", err)
			return true
		}
		// Applied=false is expected when the original COMMIT succeeded but
		// its acknowledgement was lost. Accounting still belongs to us.
		pending.complete(result)
		pending.done = true
		e.pending.Delete(key)
		return true
	})
}

func (e *Engine) Run(ctx context.Context, logger *slog.Logger) {
	timer := time.NewTicker(30 * time.Second)
	defer timer.Stop()
	for {
		e.Maintain(ctx, logger)
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
	}
}

// Flush runs after completion producers have drained, independently of the
// cancelled maintenance context. Remaining failures require operator recovery;
// neither the queued input nor its downstream callback survives process exit.
func (e *Engine) Flush(ctx context.Context, logger *slog.Logger) {
	e.Maintain(ctx, logger)
	e.pending.Range(func(key, value any) bool {
		logger.Error("consumer settlement unresolved at shutdown; financial reconciliation required", "request_id", key)
		return true
	})
}
