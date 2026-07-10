package api

import (
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestJobSettlementGate_SharedAcrossAttempts proves the M0.1 fix: primary and
// backup PendingRequests with distinct RequestIDs share one JobSettlementGate,
// so only one FinalizeReservation can win the shared base reservation.
func TestJobSettlementGate_SharedAcrossAttempts(t *testing.T) {
	gate := registry.NewJobSettlementGate()
	primary := &registry.PendingRequest{
		RequestID:            "primary-attempt",
		ReservedMicroUSD:     1_000_000,
		BaseReservedMicroUSD: 1_000_000,
		JobSettlement:        gate,
	}
	backup := &registry.PendingRequest{
		RequestID:            "backup-attempt",
		ReservedMicroUSD:     1_000_000,
		BaseReservedMicroUSD: 1_000_000,
		JobSettlement:        gate,
	}

	var wins int
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, pr := range []*registry.PendingRequest{primary, backup} {
		wg.Add(1)
		go func(pr *registry.PendingRequest) {
			defer wg.Done()
			_, err := pr.FinalizeReservation(func() error {
				mu.Lock()
				wins++
				mu.Unlock()
				return nil
			})
			if err != nil {
				t.Errorf("FinalizeReservation error: %v", err)
			}
		}(pr)
	}
	wg.Wait()
	if wins != 1 {
		t.Fatalf("expected exactly one settlement win, got %d", wins)
	}
	if !primary.IsReservationFinalized() || !backup.IsReservationFinalized() {
		t.Fatal("both attempts should observe the shared gate as finalized")
	}
}

// TestJobSettlementGate_RefundBlocksLaterSettle covers the race where the
// loser-cancel path refunds while a late complete tries to settle.
func TestJobSettlementGate_RefundBlocksLaterSettle(t *testing.T) {
	st := store.NewMemory(store.Config{AdminKey: "test"})
	_ = st.Credit("acct", 5_000_000, store.LedgerStripeDeposit, "seed")
	if err := st.Debit("acct", 1_000_000, store.LedgerCharge, "reserve"); err != nil {
		t.Fatal(err)
	}

	srv := &Server{store: st, logger: quietLogger()}
	gate := registry.NewJobSettlementGate()
	pr := &registry.PendingRequest{
		RequestID:            "attempt-1",
		ConsumerKey:          "acct",
		Model:                "test-model",
		ReservedMicroUSD:     1_000_000,
		BaseReservedMicroUSD: 1_000_000,
		JobSettlement:        gate,
	}

	if !srv.refundReservedBalance(pr, "loser_cancel") {
		t.Fatal("refund should win the gate")
	}
	ok, err := pr.FinalizeReservation(func() error {
		t.Fatal("settle must not run after refund")
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("settle must lose after refund")
	}
	if bal := st.GetBalance("acct"); bal != 5_000_000 {
		t.Fatalf("balance after refund = %d, want 5_000_000", bal)
	}
}

func TestJobSettlementGate_NilFallsBackToPerAttempt(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "solo"}
	ok, err := pr.FinalizeReservation(nil)
	if err != nil || !ok {
		t.Fatalf("nil gate first finalize: ok=%v err=%v", ok, err)
	}
	ok, err = pr.FinalizeReservation(nil)
	if err != nil || ok {
		t.Fatalf("nil gate second finalize: ok=%v err=%v", ok, err)
	}
}
