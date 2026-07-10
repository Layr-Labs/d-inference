package store

import (
	"sync"
	"sync/atomic"
	"testing"
)

func TestDebitReservation_ConcurrentPartialDebits(t *testing.T) {
	st := NewMemory(Config{AdminKey: "test"})
	_ = st.Credit("acct-d", 10_000_000, LedgerStripeDeposit, "seed")

	var okCount atomic.Int64
	var wg sync.WaitGroup
	// 20 concurrent 1M debits against 10M balance → exactly 10 should succeed.
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := st.DebitReservation("acct-d", 1_000_000, LedgerCharge, "r")
			if err == nil {
				okCount.Add(1)
			}
		}()
	}
	wg.Wait()
	if okCount.Load() != 10 {
		t.Fatalf("successful debits=%d want 10", okCount.Load())
	}
	bal, _ := st.GetBalanceWithWithdrawable("acct-d")
	if bal != 0 {
		t.Fatalf("balance=%d want 0", bal)
	}
}
