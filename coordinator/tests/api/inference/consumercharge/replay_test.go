package consumercharge_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/consumercharge"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFreshReplayCannotTakeActiveSettlementOwnership(t *testing.T) {
	for _, phase := range []string{"initial", "queued", "maintaining", "completing"} {
		for _, afterCommit := range []bool{false, true} {
			name := phase + "/before_commit"
			if afterCommit {
				name = phase + "/after_commit"
			}
			t.Run(name, func(t *testing.T) {
				s, in, original := seedSettlement(t)
				backend := &faultingSettler{MemoryStore: s, afterCommit: afterCommit}
				backend.failing.Store(true)
				var engine consumercharge.Engine
				var originalCallbacks, replayCallbacks atomic.Int32
				entered, release := make(chan struct{}), make(chan struct{})
				complete := func(result store.ConsumerChargeResult) {
					originalCallbacks.Add(1)
					if result.CollectedMicroUSD != 400 || result.ReferralRewardMicroUSD != 20 {
						t.Errorf("original result = %+v", result)
					}
					if phase == "completing" {
						close(entered)
						<-release
					}
				}
				settle := func() {
					ok, _, err := engine.Settle(original, backend, in, complete)
					if ok || !errors.Is(err, errSettlementUnavailable) {
						t.Errorf("initial settlement: ok = %v, err = %v", ok, err)
					}
				}
				logger := slog.New(slog.NewTextHandler(io.Discard, nil))
				done := make(chan struct{})
				if phase == "initial" {
					backend.blockCall, backend.entered, backend.release = 1, entered, release
					go func() { defer close(done); settle() }()
					<-entered
				} else {
					settle()
					backend.failing.Store(false)
					if phase == "queued" {
						close(done)
					} else {
						if phase == "maintaining" {
							backend.blockCall, backend.entered, backend.release = 4, entered, release
						}
						go func() { defer close(done); engine.Maintain(context.Background(), logger) }()
						<-entered
					}
				}

				// A distinct pending request has its own finalization gate and callback.
				// Even a lost acknowledgement on this replay must not confer ownership.
				replayBackend := &faultingSettler{MemoryStore: s, afterCommit: true, loseFirstAck: true}
				replay := &registry.PendingRequest{RequestID: in.JobID, ConsumerKey: in.AccountID, ReservedMicroUSD: in.ReservedMicroUSD}
				ok, _, err := engine.Settle(replay, replayBackend, in, func(store.ConsumerChargeResult) {
					replayCallbacks.Add(1)
				})
				if ok || err != nil || !replay.IsReservationFinalized() || replayBackend.calls.Load() != 0 {
					t.Errorf("active replay: ok = %v, err = %v, finalized = %v, store calls = %d", ok, err, replay.IsReservationFinalized(), replayBackend.calls.Load())
				}
				close(release)
				<-done
				backend.failing.Store(false)
				engine.Maintain(context.Background(), logger)
				engine.Maintain(context.Background(), logger)
				if originalCallbacks.Load() != 1 || replayCallbacks.Load() != 0 {
					t.Errorf("callbacks: original = %d, replay = %d; want 1 and 0", originalCallbacks.Load(), replayCallbacks.Load())
				}
				assertSettlementLedger(t, s, true)
			})
		}
	}
}
