package service

import (
	"context"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type delayedHistoricalBackfill struct {
	*store.MemoryStore
	calls atomic.Int32
}

func (s *delayedHistoricalBackfill) BackfillMachineInventory(context.Context, int) (int, error) {
	if s.calls.Add(1) == 2 {
		return 1, nil // A recent skipped row became historical later.
	}
	return 0, nil
}

func TestBackfillRechecksAfterInitiallyEmptyBatch(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		st := &delayedHistoricalBackfill{MemoryStore: store.NewMemory(store.Config{})}
		s := New(ctx, Config{}, Dependencies{Store: st})
		s.startMachineInventoryBackfill(ctx)
		time.Sleep(5 * time.Second)
		synctest.Wait()
		if st.calls.Load() != 1 {
			t.Fatal("first bounded historical scan did not run")
		}
		time.Sleep(time.Minute)
		synctest.Wait()
		if st.calls.Load() != 2 {
			t.Fatal("backfill stopped forever after an initially empty batch")
		}
		time.Sleep(5 * time.Second)
		synctest.Wait()
		if st.calls.Load() != 3 {
			t.Fatal("backfill did not resume normal batch cadence")
		}
		cancel()
		synctest.Wait()
	})
}
