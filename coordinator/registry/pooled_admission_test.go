package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestProviderPooledTokenBudget(t *testing.T) {
	cases := []struct {
		name      string
		slots     []protocol.BackendSlotCapacity
		used      int64
		committed int64
		total     int64
	}{
		{name: "nil_slots"},
		{
			name: "single_slot",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: 1_000, QueuedTokenBudget: 500, MaxTokensPotential: 3_000},
			},
			used:      1_500,
			committed: 3_000, // potential dominates used+queued
			total:     10_000,
		},
		{
			name: "two_slots_shared_headroom_counted_once",
			// Both slots see the same 8k shared free headroom:
			// maxA = 2k committed + 8k, maxB = 1k committed + 8k.
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: 2_000},
				{Model: "b", ActiveTokenBudgetMax: 9_000, ActiveTokenBudgetUsed: 1_000},
			},
			used:      3_000,
			committed: 3_000,
			total:     11_000, // 3k committed + 8k shared free ONCE (not 19k)
		},
		{
			name: "budgetless_slot_ignored_negatives_floored",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: -50, MaxTokensPotential: -10},
				{Model: "legacy", ActiveTokenBudgetMax: 0, ActiveTokenBudgetUsed: 5_000},
			},
			used:      0,
			committed: 0,
			total:     10_000,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := providerPooledTokenBudget(tc.slots)
			if got.used != tc.used || got.committed != tc.committed || got.total != tc.total {
				t.Fatalf("providerPooledTokenBudget = %+v, want {used:%d committed:%d total:%d}",
					got, tc.used, tc.committed, tc.total)
			}
		})
	}
}

// TestPooledAdmissionCoResidencyDoubleSpend is the heartbeat-gap regression,
// driven through the REAL reservation path: two co-resident models report
// per-slot maxes that each equal the ONE shared 10k KV pool. A burst to model
// A consumes the whole pool coordinator-side while the provider's heartbeat
// still reads used=0 — the old per-slot check (same-model pending only) then
// happily admitted model B against ITS stale slot max, double-spending the
// pool. The pooled check must reject B. Fails without the
// pooledBudgetAdmits call in freeMemoryAdmits.
func TestPooledAdmissionCoResidencyDoubleSpend(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 10_000,
	})
	p.mu.Unlock()

	// Burst model A (gpt-oss): five requests × (100 prompt + 1_900 max) =
	// 10_000 tokens — exactly the pool — all inside one heartbeat gap.
	for i := 0; i < 5; i++ {
		pr := &PendingRequest{
			RequestID:             fmt.Sprintf("burst-%d", i),
			Model:                 gptossBuild,
			EstimatedPromptTokens: 100,
			RequestedMaxTokens:    1_900,
		}
		if got := reg.ReserveProvider(gptossBuild, pr); got == nil {
			t.Fatalf("burst request %d rejected; 5×2k must fit the 10k pool", i)
		}
	}
	// A sixth same-model request must be rejected (slot and pool both full) —
	// the pre-existing per-slot behavior, unchanged.
	if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
		RequestID: "burst-overflow", Model: gptossBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
	}); got != nil {
		t.Fatalf("6th same-model request admitted past the slot budget on %q", got.ID)
	}

	// Model B (gemma) within the same gap: B's slot still reads max 10_000 /
	// used 0, so the old check admits — but the shared pool is already fully
	// pending to A. Must be rejected.
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "victim", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
	}); got != nil {
		t.Fatalf("gemma admitted during the heartbeat gap — co-resident double-spend of the shared KV pool (provider %q)", got.ID)
	}
}

// TestPooledAdmissionAllowsCoResidentWithinPool is the non-regression control:
// when the pool has real headroom left, a co-resident model's request IS
// admitted — the pooled gate only charges what is actually pending.
func TestPooledAdmissionAllowsCoResidentWithinPool(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 10_000,
	})
	p.mu.Unlock()

	for i := 0; i < 2; i++ { // 4k of the 10k pool
		pr := &PendingRequest{
			RequestID:             fmt.Sprintf("burst-%d", i),
			Model:                 gptossBuild,
			EstimatedPromptTokens: 100,
			RequestedMaxTokens:    1_900,
		}
		if got := reg.ReserveProvider(gptossBuild, pr); got == nil {
			t.Fatalf("burst request %d rejected with pool mostly free", i)
		}
	}
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "fits", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
	}); got == nil {
		t.Fatal("gemma rejected although the pool has 6k headroom (pooled gate over-rejecting)")
	}
}

// TestFreeMemoryAdmitsSingleModelUnchanged pins that the pooled check is
// arithmetically inert for single-model providers: for one budget slot the
// pool reduces to that slot's own budget and the admission boundary is
// byte-for-byte the old per-slot one — including the case where
// MaxTokensPotential dominates used+queued in the committed baseline.
func TestFreeMemoryAdmitsSingleModelUnchanged(t *testing.T) {
	slot := protocol.BackendSlotCapacity{
		Model:                 "m",
		ActiveTokenBudgetMax:  10_000,
		ActiveTokenBudgetUsed: 3_000,
		QueuedTokenBudget:     500,
		MaxTokensPotential:    6_000,
	}
	// Old per-slot formula: used+queued + max(0, pending − max(used+queued,
	// potential)) + req ≤ max → 3_500 + 1_000 + req ≤ 10_000 → req ≤ 5_500.
	mkSnap := func(pending int) routingSnapshot {
		return routingSnapshot{
			pendingMaxTokens:          pending,
			pendingMaxTokensAllModels: pending, // single model: identical
			activeTokenBudgetUsed:     slot.ActiveTokenBudgetUsed,
			activeTokenBudgetMax:      slot.ActiveTokenBudgetMax,
			queuedTokenBudget:         slot.QueuedTokenBudget,
			maxTokensPotential:        slot.MaxTokensPotential,
			pooledTokenBudget:         providerPooledTokenBudget([]protocol.BackendSlotCapacity{slot}),
		}
	}
	if !freeMemoryAdmits(mkSnap(7_000), 0, 5_500) {
		t.Fatal("request at the exact old boundary (5_500) rejected — pooled check changed single-model behavior")
	}
	if freeMemoryAdmits(mkSnap(7_000), 0, 5_501) {
		t.Fatal("request past the old boundary (5_501) admitted — budget admission loosened")
	}
}

// TestFreeMemoryAdmitsPooledRejectsGapDoubleSpend is the pure-function version
// of the double-spend regression (fails without the pooledBudgetAdmits call):
// model B's own slot budget admits, but the all-models pending has consumed
// the pool.
func TestFreeMemoryAdmitsPooledRejectsGapDoubleSpend(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000},
		{Model: "b", ActiveTokenBudgetMax: 10_000},
	}
	snap := routingSnapshot{
		// Snapshot for model B: no same-model pending, stale heartbeat (used 0).
		pendingMaxTokens:          0,
		pendingMaxTokensAllModels: 10_000, // model A's in-gap burst
		activeTokenBudgetMax:      10_000,
		pooledTokenBudget:         providerPooledTokenBudget(slots),
	}
	if freeMemoryAdmits(snap, 100, 1_900) {
		t.Fatal("admitted 2k tokens into a pool with 10k already pending to a co-resident model (per-slot double-spend)")
	}
	// Same snapshot with only 4k pending across models → admits.
	snap.pendingMaxTokensAllModels = 4_000
	if !freeMemoryAdmits(snap, 100, 1_900) {
		t.Fatal("rejected 2k tokens although the pool has 6k of headroom")
	}
}

// TestFreeMemoryAdmitsLegacyProviderUnchanged: providers that report no token
// budget (ActiveTokenBudgetMax == 0) never reach the budget branch — the
// legacy memory-estimation path is untouched by the pooled fields.
func TestFreeMemoryAdmitsLegacyProviderUnchanged(t *testing.T) {
	snap := routingSnapshot{
		modelLoaded:               true,
		totalMemoryGB:             64,
		gpuMemoryActiveGB:         10,
		modelSizeGB:               14,
		pendingMaxTokensAllModels: 1 << 30, // must be ignored on the legacy path
	}
	if !freeMemoryAdmits(snap, 100, 1_900) {
		t.Fatal("legacy (budget-less) admission changed: loaded model with free memory must admit")
	}
}
