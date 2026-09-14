package settlement

import (
	"errors"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestServiceReservationConcurrentAvoidsDebitHotRow(t *testing.T) {
	srv, st := newServiceHoldTestService(t, errors.New("hot row unavailable"))
	createServiceUser(t, st, "svc-hotrow")
	if err := st.Credit("svc-hotrow", 10_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}

	const workers = 32
	var wg sync.WaitGroup
	errs := make(chan error, workers)
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			serviceMode, err := srv.Reserve("svc-hotrow", "model", 100_000)
			if err != nil {
				errs <- err
				return
			}
			if !serviceMode {
				errs <- errors.New("expected service reservation mode")
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := st.DebitCount(); got != 0 {
		t.Fatalf("Debit calls = %d, want 0", got)
	}
}
