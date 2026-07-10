package api

import (
	"sync"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestJobSettlementGate_ConcurrentFinalize(t *testing.T) {
	g := registry.NewJobSettlementGate()
	var wins atomic.Int64
	var wg sync.WaitGroup
	for i := 0; i < 64; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, err := g.Finalize(func() error { return nil })
			if err != nil {
				t.Errorf("finalize: %v", err)
				return
			}
			if ok {
				wins.Add(1)
			}
		}()
	}
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("wins=%d want 1", wins.Load())
	}
	if !g.IsFinalized() {
		t.Fatal("expected finalized")
	}
}
