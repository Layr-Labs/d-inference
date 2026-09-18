package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestPooledKVRateTableMatchesMapSemantics pins the inline table against the
// map it replaced: last write wins per model, unknown reads as 0, and entries
// past the inline capacity spill without losing or reordering anything.
func TestPooledKVRateTableMatchesMapSemantics(t *testing.T) {
	var pool pooledTokenBudget
	ref := map[string]int64{}
	set := func(model string, rate int64) {
		pool.setKVRate(model, rate)
		ref[model] = rate
	}
	for i := 0; i < 3*pooledKVRateInline; i++ {
		set(fmt.Sprintf("m-%d", i), int64(1000+i))
	}
	set("m-0", 5)                                     // overwrite inline
	set(fmt.Sprintf("m-%d", 2*pooledKVRateInline), 6) // overwrite spilled
	for model, want := range ref {
		if got := pool.kvRateFor(model); got != want {
			t.Fatalf("kvRateFor(%s) = %d, want %d", model, got, want)
		}
	}
	if got := pool.kvRateFor("absent"); got != 0 {
		t.Fatalf("unknown model rate = %d, want 0", got)
	}
	if pool.kvRateCount != len(ref) {
		t.Fatalf("kvRateCount = %d, want %d", pool.kvRateCount, len(ref))
	}
}

// TestPooledBudgetReconstructionAllocatesNothing pins the hot-path contract:
// reconstructing a provider's pool from a typical multi-slot heartbeat does
// not touch the heap.
func TestPooledBudgetReconstructionAllocatesNothing(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 100_000, ActiveTokenBudgetUsed: 1_000, KVBytesPerToken: 98_304},
		{Model: "b", ActiveTokenBudgetMax: 80_000, KVBytesPerToken: 50_000},
		{Model: "c", ActiveTokenBudgetMax: 60_000, QueuedTokenBudget: 500, KVBytesPerToken: 20_000},
	}
	var sink int64
	allocs := testing.AllocsPerRun(200, func() {
		pool := providerPooledTokenBudgetWithLayout(slots, privateSlotGrants)
		sink += pool.kvRateFor("b") + pool.totalBytes
	})
	if allocs != 0 {
		t.Fatalf("pool reconstruction allocated %v per run; want 0", allocs)
	}
	if sink == 0 {
		t.Fatal("pool reconstruction produced nothing")
	}
}
