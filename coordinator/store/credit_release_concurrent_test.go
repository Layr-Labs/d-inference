package store

import (
	"sync"
	"sync/atomic"
	"testing"
)

func TestCreditReservationRelease_RestoresWithdrawableExactly(t *testing.T) {
	st := NewMemory(Config{AdminKey: "test"})
	_ = st.Credit("acct-r", 5_000_000, LedgerStripeDeposit, "dep")
	_ = st.CreditWithdrawable("acct-r", 5_000_000, LedgerPayout, "earn")

	reservedWdr, err := st.DebitReservation("acct-r", 7_000_000, LedgerCharge, "reserve")
	if err != nil {
		t.Fatal(err)
	}
	// Non-wdr 5M first → reservedWdr = 2M
	if reservedWdr != 2_000_000 {
		t.Fatalf("reservedWdr=%d", reservedWdr)
	}

	var wg sync.WaitGroup
	var okCount atomic.Int64
	// Concurrent releases of the same reservation must be idempotent / safe.
	// Only one logical release should restore funds; extras should no-op or error cleanly.
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := st.CreditReservationRelease("acct-r", 7_000_000, reservedWdr, LedgerRefund, "rel"); err == nil {
				okCount.Add(1)
			}
		}()
	}
	wg.Wait()
	if okCount.Load() < 1 {
		t.Fatal("expected at least one successful release")
	}
	bal, wdr := st.GetBalanceWithWithdrawable("acct-r")
	if bal != 10_000_000 {
		t.Fatalf("balance=%d want 10_000_000 (idempotent release)", bal)
	}
	if wdr != 5_000_000 {
		t.Fatalf("withdrawable=%d want 5_000_000", wdr)
	}
	if okCount.Load() != 8 {
		// All calls succeed; only the first mutates.
		t.Fatalf("okCount=%d want 8", okCount.Load())
	}
}
