package store

import (
	"sync"
	"sync/atomic"
	"testing"
)

func TestApplyStripeDeposit_ConcurrentSameEvent(t *testing.T) {
	st := NewMemory(Config{AdminKey: "test"})
	bs := &BillingSession{
		ID:             "bs-c",
		AccountID:      "acct-c",
		PaymentMethod:  "stripe",
		AmountMicroUSD: 2_000_000,
		ExternalID:     "cs_concurrent",
		Status:         "pending",
	}
	if err := st.CreateBillingSession(bs); err != nil {
		t.Fatal(err)
	}

	var appliedCount atomic.Int64
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			applied, err := st.ApplyStripeDeposit(
				"evt_concurrent",
				"cs_concurrent",
				"acct-c",
				"bs-c",
				2_000_000,
				LedgerStripeDeposit,
			)
			if err != nil {
				t.Errorf("ApplyStripeDeposit: %v", err)
				return
			}
			if applied {
				appliedCount.Add(1)
			}
		}()
	}
	wg.Wait()
	if appliedCount.Load() != 1 {
		t.Fatalf("applied=%d want 1", appliedCount.Load())
	}
	if bal := st.GetBalance("acct-c"); bal != 2_000_000 {
		t.Fatalf("balance=%d", bal)
	}
}
