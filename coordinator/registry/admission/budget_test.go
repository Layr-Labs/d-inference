package admission

import "testing"

// These model-local budget cases previously lived in scheduler_memory_admission_test.
func TestSlotTokenBudget(t *testing.T) {
	slot := SlotBudget{Used: 28_000, Maximum: 32_768}
	if CheckSlot(slot, 500+4096) != Admit {
		t.Fatal("28000 + 4596 must fit")
	}
	if CheckSlot(slot, 500+4500) != Reject {
		t.Fatal("28000 + 5000 must not fit")
	}
}

func TestSlotIncludesQueuedBudget(t *testing.T) {
	slot := SlotBudget{Used: 20_000, Queued: 10_000, Maximum: 32_768}
	if CheckSlot(slot, 4596) != Reject {
		t.Fatal("active + queued + request exceeds budget")
	}
	slot.Queued = 0
	if CheckSlot(slot, 4596) != Admit {
		t.Fatal("must fit without queued budget")
	}
}

func TestSlotBudgetFencesAndDeduplication(t *testing.T) {
	for _, tc := range []struct {
		name    string
		slot    SlotBudget
		request int64
		want    BudgetDecision
	}{
		{"legacy", SlotBudget{}, 1, NeedsMemoryCheck},
		{"blocked", SlotBudget{Blocked: true}, 0, Reject},
		{"clamped_legacy", SlotBudget{Clamped: true}, 0, Reject},
		{"known_zero", SlotBudget{KVBytesPerToken: 1}, 0, Reject},
		{"negative_rate_absent", SlotBudget{KVBytesPerToken: -1}, 1, NeedsMemoryCheck},
		{"heartbeat_dedup", SlotBudget{Used: 30, Queued: 20, Pending: 50, Maximum: 100}, 50, Admit},
		{"potential_dedup", SlotBudget{Used: 30, Queued: 20, Pending: 80, Potential: 80, Maximum: 100}, 50, Admit},
		{"gap_reserved", SlotBudget{Used: 30, Queued: 20, Pending: 81, Potential: 80, Maximum: 100}, 50, Reject},
		{"negative_baseline", SlotBudget{Used: -5, Queued: -5, Potential: -1, Pending: 0, Maximum: 1}, 11, Admit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := CheckSlot(tc.slot, tc.request); got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}

func TestPoolBudgetModes(t *testing.T) {
	for _, tc := range []struct {
		name      string
		pool      PoolBudget
		remaining int64
	}{
		{"unreported", PoolBudget{}, -1},
		{"known_zero", PoolBudget{Reported: true}, 0},
		{"tokens", PoolBudget{Reported: true, Total: 100, Used: 20, Committed: 30, Pending: 40}, 70},
		{"dedup_floor", PoolBudget{Reported: true, Total: 100, Used: 20, Committed: 30, Pending: 10}, 80},
		{"bytes", PoolBudget{Reported: true, Total: 100, ByteMode: true, PendingBytesKnown: true, TotalBytes: 1000, UsedBytes: 200, CommittedBytes: 300, PendingBytes: 400, Rate: 30}, 23},
		{"pending_unknown", PoolBudget{Reported: true, Total: 100, Used: 20, ByteMode: true, TotalBytes: 1, Rate: 30}, 80},
		{"rate_absent", PoolBudget{Reported: true, Total: 100, Used: 20, ByteMode: true, PendingBytesKnown: true, TotalBytes: 1}, 80},
		{"shrunk_grant", PoolBudget{Reported: true, Total: 10, Used: 20}, 0},
		{"pending_exhausted", PoolBudget{Reported: true, Total: 10, Pending: 20}, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := PoolRemaining(tc.pool); got != tc.remaining {
				t.Fatalf("remaining=%d, want %d", got, tc.remaining)
			}
			for request := int64(1); request <= 101; request++ {
				want := tc.remaining < 0 || request <= tc.remaining
				if got := PoolAdmits(tc.pool, request); got != want {
					t.Fatalf("request=%d: admit=%t, want %t", request, got, want)
				}
			}
		})
	}
	if !PoolAdmits(PoolBudget{Reported: true}, 0) || PoolAdmits(PoolBudget{Reported: true}, -1) {
		t.Fatal("known-zero pool must admit exactly zero tokens")
	}
	if PoolAdmits(PoolBudget{Reported: true, Total: 1}, -1) {
		t.Fatal("negative request admitted")
	}
}
