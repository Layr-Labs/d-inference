package consumercharge_test

import (
	"context"
	"errors"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/consumercharge"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFlushRetriesUntilSettlementRecovers(t *testing.T) {
	for _, afterCommit := range []bool{false, true} {
		name := "before_commit"
		if afterCommit {
			name = "after_commit"
		}
		t.Run(name, func(t *testing.T) {
			s, in, pr := seedSettlement(t)
			backend := &faultingSettler{MemoryStore: s, afterCommit: afterCommit, failThrough: 5}
			var engine consumercharge.Engine
			var callbacks atomic.Int32
			ok, _, err := engine.Settle(pr, backend, in, func(result store.ConsumerChargeResult) {
				callbacks.Add(1)
				if result.CollectedMicroUSD != 400 || result.ReferralRewardMicroUSD != 20 {
					t.Errorf("unexpected recovered settlement: %+v", result)
				}
			})
			if ok || !errors.Is(err, errSettlementUnavailable) || backend.calls.Load() != 3 {
				t.Fatalf("initial settlement: ok=%v err=%v calls=%d", ok, err, backend.calls.Load())
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			logger := slog.New(slog.DiscardHandler)
			engine.Flush(ctx, logger)
			if ctx.Err() != nil || callbacks.Load() != 1 || backend.calls.Load() != 6 {
				t.Fatalf("flush stopped before recovery: context=%v callbacks=%d calls=%d", ctx.Err(), callbacks.Load(), backend.calls.Load())
			}
			engine.Flush(ctx, logger)
			if callbacks.Load() != 1 || backend.calls.Load() != 6 {
				t.Fatal("successful flush left the settlement queued")
			}
			assertSettlementLedger(t, s, true)
		})
	}
}

func TestFlushDeadlineRetainsUnresolvedSettlement(t *testing.T) {
	s, in, pr := seedSettlement(t)
	backend := &faultingSettler{MemoryStore: s}
	backend.failing.Store(true)
	var engine consumercharge.Engine
	var callbacks atomic.Int32
	if ok, _, err := engine.Settle(pr, backend, in, func(store.ConsumerChargeResult) { callbacks.Add(1) }); ok || !errors.Is(err, errSettlementUnavailable) {
		t.Fatalf("initial settlement: ok=%v err=%v", ok, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	logger := slog.New(slog.DiscardHandler)
	engine.Flush(ctx, logger)
	if !errors.Is(ctx.Err(), context.DeadlineExceeded) || callbacks.Load() != 0 {
		t.Fatalf("flush did not retain unresolved work until deadline: context=%v callbacks=%d", ctx.Err(), callbacks.Load())
	}
	assertSettlementLedger(t, s, false)
	backend.failing.Store(false)
	engine.Maintain(context.Background(), logger)
	if callbacks.Load() != 1 {
		t.Fatal("deadline discarded unresolved settlement")
	}
	assertSettlementLedger(t, s, true)
}
