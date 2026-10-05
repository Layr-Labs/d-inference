package admission_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry/admission"
)

// These model-local budget cases previously lived in scheduler_memory_admission_test.
func TestSlotTokenBudget(t *testing.T) {
	slot := production.SlotBudget{Used: 28_000, Maximum: 32_768}
	if production.CheckSlot(slot, 500+4096) != production.Admit {
		t.Fatal("28000 + 4596 must fit")
	}
	if production.CheckSlot(slot, 500+4500) != production.Reject {
		t.Fatal("28000 + 5000 must not fit")
	}
}

func TestSlotIncludesQueuedBudget(t *testing.T) {
	slot := production.SlotBudget{Used: 20_000, Queued: 10_000, Maximum: 32_768}
	if production.CheckSlot(slot, 4596) != production.Reject {
		t.Fatal("active + queued + request exceeds budget")
	}
	slot.Queued = 0
	if production.CheckSlot(slot, 4596) != production.Admit {
		t.Fatal("must fit without queued budget")
	}
}

func TestSlotBudgetFencesAndDeduplication(t *testing.T) {
	for _, tc := range []struct {
		name    string
		slot    production.SlotBudget
		request int64
		want    production.BudgetDecision
	}{
		{"legacy", production.SlotBudget{}, 1, production.NeedsMemoryCheck},
		{"blocked", production.SlotBudget{Blocked: true}, 0, production.Reject},
		{"clamped_legacy", production.SlotBudget{Clamped: true}, 0, production.Reject},
		{"known_zero", production.SlotBudget{KVBytesPerToken: 1}, 0, production.Reject},
		{"negative_rate_absent", production.SlotBudget{KVBytesPerToken: -1}, 1, production.NeedsMemoryCheck},
		{"heartbeat_dedup", production.SlotBudget{Used: 30, Queued: 20, Pending: 50, Maximum: 100}, 50, production.Admit},
		{"potential_dedup", production.SlotBudget{Used: 30, Queued: 20, Pending: 80, Potential: 80, Maximum: 100}, 50, production.Admit},
		{"gap_reserved", production.SlotBudget{Used: 30, Queued: 20, Pending: 81, Potential: 80, Maximum: 100}, 50, production.Reject},
		{"negative_baseline", production.SlotBudget{Used: -5, Queued: -5, Potential: -1, Pending: 0, Maximum: 1}, 11, production.Admit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := production.CheckSlot(tc.slot, tc.request); got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}

func TestPoolBudgetModes(t *testing.T) {
	for _, tc := range []struct {
		name      string
		pool      production.PoolBudget
		remaining int64
	}{
		{"unreported", production.PoolBudget{}, -1},
		{"known_zero", production.PoolBudget{Reported: true}, 0},
		{"tokens", production.PoolBudget{Reported: true, Total: 100, Used: 20, Committed: 30, Pending: 40}, 70},
		{"dedup_floor", production.PoolBudget{Reported: true, Total: 100, Used: 20, Committed: 30, Pending: 10}, 80},
		{"bytes", production.PoolBudget{Reported: true, Total: 100, ByteMode: true, PendingBytesKnown: true, TotalBytes: 1000, UsedBytes: 200, CommittedBytes: 300, PendingBytes: 400, Rate: 30}, 23},
		{"pending_unknown", production.PoolBudget{Reported: true, Total: 100, Used: 20, ByteMode: true, TotalBytes: 1, Rate: 30}, 80},
		{"rate_absent", production.PoolBudget{Reported: true, Total: 100, Used: 20, ByteMode: true, PendingBytesKnown: true, TotalBytes: 1}, 80},
		{"shrunk_grant", production.PoolBudget{Reported: true, Total: 10, Used: 20}, 0},
		{"pending_exhausted", production.PoolBudget{Reported: true, Total: 10, Pending: 20}, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := production.PoolRemaining(tc.pool); got != tc.remaining {
				t.Fatalf("remaining=%d, want %d", got, tc.remaining)
			}
			for request := int64(1); request <= 101; request++ {
				want := tc.remaining < 0 || request <= tc.remaining
				if got := production.PoolAdmits(tc.pool, request); got != want {
					t.Fatalf("request=%d: admit=%t, want %t", request, got, want)
				}
			}
		})
	}
	if !production.PoolAdmits(production.PoolBudget{Reported: true}, 0) || production.PoolAdmits(production.PoolBudget{Reported: true}, -1) {
		t.Fatal("known-zero pool must admit exactly zero tokens")
	}
	if production.PoolAdmits(production.PoolBudget{Reported: true, Total: 1}, -1) {
		t.Fatal("negative request admitted")
	}
}
