package api

import "testing"

func TestProviderCompletionBarrierWaitsForSettlementAndIsIdempotent(t *testing.T) {
	var barrier providerCompletionBarrier
	first, second := barrier.begin(), barrier.begin()
	pending := barrier.snapshot()
	if len(pending) != 2 {
		t.Fatal("lost terminal worker")
	}
	first()
	first() // duplicate cleanup cannot close twice or lose the other worker
	if len(barrier.snapshot()) != 1 {
		t.Fatal("duplicate completion changed pending settlement")
	}
	third := barrier.begin() // later frames are outside this barrier's snapshot
	second()
	for _, done := range pending {
		select {
		case <-done:
		default:
			t.Fatal("settled terminal still blocked")
		}
	}
	if len(barrier.snapshot()) != 1 {
		t.Fatal("barrier incorrectly consumed later work")
	}
	third()
	if len(barrier.snapshot()) != 0 {
		t.Fatal("settlement leaked")
	}
}
