package store

import (
	"sync"
	"sync/atomic"
	"testing"
)

func TestDebitReservation_InsufficientFundsUnderContention(t *testing.T) {
	st := NewMemory(Config{AdminKey: "test"})
	_ = st.Credit("acct-i", 3_000_000, LedgerStripeDeposit, "seed")

	var okCount, failCount atomic.Int64
	var wg sync.WaitGroup
	// 10 goroutines each trying to debit 1M against 3M → exactly 3 succeed.
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := st.DebitReservation("acct-i", 1_000_000, LedgerCharge, "r")
			if err == nil {
				okCount.Add(1)
			} else {
				failCount.Add(1)
			}
		}()
	}
	wg.Wait()
	if okCount.Load() != 3 {
		t.Fatalf("ok=%d want 3", okCount.Load())
	}
	if failCount.Load() != 7 {
		t.Fatalf("fail=%d want 7", failCount.Load())
	}
	bal, _ := st.GetBalanceWithWithdrawable("acct-i")
	if bal != 0 {
		t.Fatalf("balance=%d want 0", bal)
	}
}
