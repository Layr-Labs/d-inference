package consumercharge_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/consumercharge"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

var errSettlementUnavailable = errors.New("settlement acknowledgement unavailable")

type faultingSettler struct {
	*memory.MemoryStore
	afterCommit  bool
	loseFirstAck bool
	failThrough  int32
	failing      atomic.Bool
	calls        atomic.Int32
	blockCall    int32
	entered      chan struct{}
	release      chan struct{}
}

func (s *faultingSettler) FinalizeConsumerCharge(in store.ConsumerChargeSettlement) (store.ConsumerChargeResult, error) {
	call := s.calls.Add(1)
	if call == s.blockCall {
		close(s.entered)
		<-s.release
	}
	fail := s.failing.Load() || call <= s.failThrough || (s.loseFirstAck && call == 1)
	if fail && !s.afterCommit {
		return store.ConsumerChargeResult{}, errSettlementUnavailable
	}
	result, err := s.MemoryStore.FinalizeConsumerCharge(in)
	if err != nil {
		return result, err
	}
	if fail {
		// The caller cannot observe the committed result when its acknowledgement is lost.
		return store.ConsumerChargeResult{}, errSettlementUnavailable
	}
	return result, nil
}

func seedSettlement(t *testing.T) (*memory.MemoryStore, store.ConsumerChargeSettlement, *registry.PendingRequest) {
	t.Helper()
	s := memory.NewMemory(store.Config{})
	in := store.ConsumerChargeSettlement{
		AccountID: "consumer", JobID: "job", ReservedMicroUSD: 600,
		CostMicroUSD: 400, ReferralEnabled: true,
	}
	if err := s.CreateReferrer("referrer", "referrer"); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordReferral("referrer", in.AccountID); err != nil {
		t.Fatal(err)
	}
	if err := s.Credit(in.AccountID, 1000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := s.Debit(in.AccountID, in.ReservedMicroUSD, store.LedgerCharge, in.JobID); err != nil {
		t.Fatal(err)
	}
	return s, in, &registry.PendingRequest{
		RequestID: in.JobID, ConsumerKey: in.AccountID, ReservedMicroUSD: in.ReservedMicroUSD,
	}
}

func assertSettlementLedger(t *testing.T, s *memory.MemoryStore, committed bool) {
	t.Helper()
	wantBalance, wantEntries, wantReward := int64(400), 2, int64(0)
	if committed {
		wantBalance, wantEntries, wantReward = 600, 3, 20
	}
	if got := s.GetBalance("consumer"); got != wantBalance {
		t.Errorf("consumer balance = %d, want %d", got, wantBalance)
	}
	entries := s.LedgerHistory("consumer")
	if len(entries) != wantEntries {
		t.Errorf("consumer ledger has %d entries, want %d: %+v", len(entries), wantEntries, entries)
	}
	var refunds int
	for _, entry := range entries {
		if entry.Type == store.LedgerRefund {
			refunds++
			if entry.AmountMicroUSD != 200 || entry.Reference != "job" {
				t.Errorf("unexpected settlement refund: %+v", entry)
			}
		}
	}
	if want := wantEntries - 2; refunds != want {
		t.Errorf("refund entries = %d, want %d", refunds, want)
	}
	if balance, withdrawable := s.GetBalance("referrer"), s.GetWithdrawableBalance("referrer"); balance != wantReward || withdrawable != wantReward {
		t.Errorf("referrer balance/withdrawable = %d/%d, want %d/%d", balance, withdrawable, wantReward, wantReward)
	}
	rewards := s.LedgerHistory("referrer")
	if len(rewards) != wantEntries-2 {
		t.Errorf("referrer ledger: %+v", rewards)
	}
	for _, reward := range rewards {
		if reward.Type != store.LedgerReferralReward || reward.AmountMicroUSD != 20 || reward.Reference != "job" {
			t.Errorf("unexpected referral reward: %+v", reward)
		}
	}
}

// Err is called after Range has selected the pending charge, before its lock.
// The barrier makes every maintenance worker contend for that same charge,
// including workers that resume after the successful worker deletes it.
type maintenanceBarrier struct {
	context.Context
	selected chan struct{}
}

func (c maintenanceBarrier) Err() error {
	c.selected <- struct{}{}
	return c.Context.Err()
}

func TestPersistentSettlementFailureRecoversExactlyOnce(t *testing.T) {
	for _, afterCommit := range []bool{false, true} {
		name := "before_commit"
		if afterCommit {
			name = "after_commit"
		}
		t.Run(name, func(t *testing.T) {
			s, in, pr := seedSettlement(t)
			backend := &faultingSettler{
				MemoryStore: s, afterCommit: afterCommit, blockCall: 1,
				entered: make(chan struct{}), release: make(chan struct{}),
			}
			backend.failing.Store(true)
			var engine consumercharge.Engine
			var callbacks, refunds atomic.Int32
			complete := func(result store.ConsumerChargeResult) {
				callbacks.Add(1)
				if result.CollectedMicroUSD != 400 || result.ReferralRewardMicroUSD != 20 || result.Uncollected || result.Applied == afterCommit {
					t.Errorf("recovered result = %+v, afterCommit = %v", result, afterCommit)
				}
			}
			settled := make(chan struct{})
			go func() {
				defer close(settled)
				ok, _, err := engine.Settle(pr, backend, in, complete)
				if ok || !errors.Is(err, errSettlementUnavailable) {
					t.Errorf("persistent failure: settled = %v, err = %v", ok, err)
				}
			}()
			<-backend.entered

			// Settlement already owns FinalizeReservation before the generic
			// terminal/refund path is started.
			refundStarted, refundDone := make(chan struct{}), make(chan struct{})
			go func() {
				defer close(refundDone)
				close(refundStarted)
				ok, err := pr.FinalizeReservation(func() error {
					refunds.Add(1)
					return s.Credit(in.AccountID, in.ReservedMicroUSD, store.LedgerRefund, "generic-refund")
				})
				if ok || err != nil {
					t.Errorf("generic refund was not fenced: finalized = %v, err = %v", ok, err)
				}
			}()
			<-refundStarted
			close(backend.release)
			<-settled
			<-refundDone
			if backend.calls.Load() != 3 || callbacks.Load() != 0 || refunds.Load() != 0 || !pr.IsReservationFinalized() {
				t.Fatalf("failed settlement: calls = %d, callbacks = %d, refunds = %d, finalized = %v", backend.calls.Load(), callbacks.Load(), refunds.Load(), pr.IsReservationFinalized())
			}
			assertSettlementLedger(t, s, afterCommit)

			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			engine.Maintain(context.Background(), logger)
			if backend.calls.Load() != 4 || callbacks.Load() != 0 {
				t.Fatalf("failed maintenance: calls = %d, callbacks = %d", backend.calls.Load(), callbacks.Load())
			}
			assertSettlementLedger(t, s, afterCommit)

			backend.failing.Store(false)
			backend.blockCall = 5
			backend.entered, backend.release = make(chan struct{}), make(chan struct{})
			const workers = 16
			ctx := maintenanceBarrier{Context: context.Background(), selected: make(chan struct{}, workers)}
			var wg sync.WaitGroup
			for range workers {
				wg.Add(1)
				go func() {
					defer wg.Done()
					engine.Maintain(ctx, logger)
				}()
			}
			<-backend.entered
			for range workers {
				<-ctx.selected
			}
			close(backend.release)
			wg.Wait()
			if backend.calls.Load() != 5 || callbacks.Load() != 1 {
				t.Fatalf("concurrent recovery: calls = %d, callbacks = %d; want 5 and 1", backend.calls.Load(), callbacks.Load())
			}
			assertSettlementLedger(t, s, true)
			engine.Maintain(context.Background(), logger)
			if backend.calls.Load() != 5 || callbacks.Load() != 1 {
				t.Fatal("completed charge remained queued")
			}

			fresh := &registry.PendingRequest{RequestID: in.JobID, ConsumerKey: in.AccountID, ReservedMicroUSD: in.ReservedMicroUSD}
			ok, result, err := engine.Settle(fresh, backend, in, complete)
			if ok || err != nil || result.Applied || result.CollectedMicroUSD != 400 || result.ReferralRewardMicroUSD != 20 || callbacks.Load() != 1 || !fresh.IsReservationFinalized() {
				t.Fatalf("fresh replay: settled = %v, result = %+v, err = %v, callbacks = %d", ok, result, err, callbacks.Load())
			}
			assertSettlementLedger(t, s, true)
		})
	}
}

func TestSettlementRecoversOneLostAcknowledgementInInitialCall(t *testing.T) {
	s, in, pr := seedSettlement(t)
	backend := &faultingSettler{MemoryStore: s, afterCommit: true, loseFirstAck: true}
	var engine consumercharge.Engine
	var callbacks atomic.Int32
	complete := func(result store.ConsumerChargeResult) {
		callbacks.Add(1)
		if result.Applied || result.CollectedMicroUSD != 400 || result.ReferralRewardMicroUSD != 20 || result.Uncollected {
			t.Errorf("recovered acknowledgement = %+v", result)
		}
	}
	ok, result, err := engine.Settle(pr, backend, in, complete)
	if !ok || err != nil || result.Applied || callbacks.Load() != 1 || backend.calls.Load() != 2 || !pr.IsReservationFinalized() {
		t.Fatalf("initial recovery: settled = %v, result = %+v, err = %v, calls = %d, callbacks = %d", ok, result, err, backend.calls.Load(), callbacks.Load())
	}
	assertSettlementLedger(t, s, true)
	ok, _, err = engine.Settle(pr, backend, in, complete)
	if ok || err != nil || backend.calls.Load() != 2 || callbacks.Load() != 1 {
		t.Fatalf("same request replay: settled = %v, err = %v, calls = %d, callbacks = %d", ok, err, backend.calls.Load(), callbacks.Load())
	}
	engine.Maintain(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	if backend.calls.Load() != 2 || callbacks.Load() != 1 {
		t.Fatal("initial recovery incorrectly queued reconciliation")
	}
	assertSettlementLedger(t, s, true)
}
