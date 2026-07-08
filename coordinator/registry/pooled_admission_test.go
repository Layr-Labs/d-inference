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

// TestProviderPooledTokenBudgetByteNormalization pins the byte-space
// reconstruction: per-slot token quantities scale by that slot's own
// KVBytesPerToken, the shared free headroom is the largest per-slot free BYTE
// view counted once, and a single budget slot without a KV rate disables byte
// mode for the whole pool (legacy provider build).
func TestProviderPooledTokenBudgetByteNormalization(t *testing.T) {
	// Big-KV model A: 10k tokens × 100kB/token headroom = 1 GB.
	// Small-KV model B: 100k tokens × 10kB/token = the SAME 1 GB pool.
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "b", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	}
	pool := providerPooledTokenBudget(slots)
	if !pool.byteMode {
		t.Fatal("byteMode = false with every budget slot reporting a KV rate")
	}
	if pool.totalBytes != 1_000_000_000 || pool.usedBytes != 0 || pool.committedBytes != 0 {
		t.Fatalf("byte pool = {used:%d committed:%d total:%d}, want {0 0 1e9} (shared free bytes counted once)",
			pool.usedBytes, pool.committedBytes, pool.totalBytes)
	}
	// Token space is denominated by the LARGEST free-token view (B's 100k) —
	// the very distortion byte mode exists to correct.
	if pool.total != 100_000 {
		t.Fatalf("token pool total = %d, want 100_000", pool.total)
	}

	// One budget slot without a rate → byte reconstruction impossible.
	mixed := providerPooledTokenBudget([]protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "legacy", ActiveTokenBudgetMax: 9_000},
	})
	if mixed.byteMode {
		t.Fatal("byteMode = true although a budget slot reports no KVBytesPerToken")
	}
}

// TestFreeMemoryAdmitsByteNormalizedHeterogeneousKV is the X-unit regression:
// co-resident slots with different KVBytesPerToken share ONE byte pool, so
// token counts are not a common unit. A 90k-token pending burst on the
// small-KV model (10 kB/token = 0.9 GB) leaves only 0.1 GB of the 1 GB pool,
// so a 3k-token request to the big-KV model (100 kB/token = 0.3 GB) must be
// rejected — token accounting (93k ≤ 100k) would admit it and the box OOMs.
// Fails without the byte-normalized branch in pooledBudgetAdmits.
func TestFreeMemoryAdmitsByteNormalizedHeterogeneousKV(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	}
	mkSnap := func(pendingSmallKVTokens int64) routingSnapshot {
		return routingSnapshot{
			// Snapshot for the big-KV model: no same-model pending, stale
			// heartbeat (used 0), all pending is the small-KV burst.
			activeTokenBudgetMax:      10_000,
			kvBytesPerToken:           100_000,
			pendingMaxTokensAllModels: int(pendingSmallKVTokens),
			pendingMaxBytesAllModels:  pendingSmallKVTokens * 10_000,
			pendingBytesKnown:         true,
			pooledTokenBudget:         providerPooledTokenBudget(slots),
		}
	}
	// 90k small-KV tokens pending = 0.9 GB; +0.3 GB request = 1.2 GB > 1 GB.
	if freeMemoryAdmits(mkSnap(90_000), 100, 2_900) {
		t.Fatal("admitted 0.3 GB of big-KV request into a byte pool with 0.9 GB already pending (token/byte unit confusion)")
	}
	// Control: 40k small-KV tokens pending = 0.4 GB; +0.3 GB = 0.7 GB ≤ 1 GB.
	if !freeMemoryAdmits(mkSnap(40_000), 100, 2_900) {
		t.Fatal("rejected a request although the byte pool has 0.6 GB of headroom (byte gate over-rejecting)")
	}
}

// TestFreeMemoryAdmitsByteModeCorrectsTokenOverReject is the reverse sanity
// case: when heartbeat skew leaves the token pool denominated by a SMALLER
// free view than the true byte pool, token accounting over-rejects small-KV
// work that genuinely fits in bytes. With the fix the byte check admits;
// without it the token check (61k > 50k) wrongly rejects.
func TestFreeMemoryAdmitsByteModeCorrectsTokenOverReject(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		// Big-KV slot sees 1 GB free (10k × 100 kB); small-KV slot's staler
		// view reports only 0.5 GB (50k × 10 kB). Token total = max(10k, 50k)
		// = 50k tokens; byte total = max(1 GB, 0.5 GB) = 1 GB.
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 50_000, KVBytesPerToken: 10_000},
	}
	snap := routingSnapshot{
		// Snapshot for the small-KV model with a 60k-token (0.6 GB) small-KV
		// burst pending elsewhere on the box and a 1k-token (10 MB) request.
		activeTokenBudgetMax:      50_000,
		kvBytesPerToken:           10_000,
		pendingMaxTokensAllModels: 60_000,
		pendingMaxBytesAllModels:  600_000_000,
		pendingBytesKnown:         true,
		pooledTokenBudget:         providerPooledTokenBudget(slots),
	}
	if !pooledBudgetAdmits(snap, 1_000) {
		t.Fatal("rejected 10 MB into a 1 GB byte pool holding 0.6 GB (token-unit over-rejection not corrected)")
	}
}

// TestPooledAdmissionByteDoubleSpendRealPath drives the heterogeneous-KV
// double-spend through the REAL reservation path: a small-KV burst that fits
// the pool token-wise exhausts it byte-wise, so a big-KV co-resident request
// inside the same heartbeat gap must be rejected. Fails without byte
// normalization (token accounting reads 93k ≤ 100k and admits).
func TestPooledAdmissionByteDoubleSpendRealPath(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	// gpt-oss: 10 kB/token → 100k-token view of the 1 GB shared pool.
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100_000
	p.BackendCapacity.Slots[0].KVBytesPerToken = 10_000
	// gemma: 100 kB/token → 10k-token view of the SAME 1 GB pool.
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 10_000,
		KVBytesPerToken:      100_000,
	})
	p.mu.Unlock()

	// Burst gpt-oss: nine requests × 10k tokens = 90k tokens = 0.9 GB pending.
	for i := 0; i < 9; i++ {
		pr := &PendingRequest{
			RequestID:             fmt.Sprintf("burst-%d", i),
			Model:                 gptossBuild,
			EstimatedPromptTokens: 500,
			RequestedMaxTokens:    9_500,
		}
		if got := reg.ReserveProvider(gptossBuild, pr); got == nil {
			t.Fatalf("burst request %d rejected; 9×10k tokens (0.9 GB) must fit the 1 GB pool", i)
		}
	}
	// Gemma within the same gap: 3k tokens ≤ its 10k slot view and 93k ≤ 100k
	// in token space — but 0.3 GB does NOT fit the 0.1 GB of byte headroom.
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "victim", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 2_900,
	}); got != nil {
		t.Fatalf("gemma admitted during the heartbeat gap — token-unit accounting double-spent the byte pool (provider %q)", got.ID)
	}
}

// TestFreeMemoryAdmitsColdModelChargesPool is the cold-slot pooled-gate
// regression (pure-function form): the target model reports NO budget slot
// (activeTokenBudgetMax == 0, not loaded here), so it skips the budget branch
// entirely — but a resident co-model's slot reports the shared pool, and the
// in-gap pending burst has already consumed it. The cold request must be
// charged against the pool too, or it double-spends the same KV the resident
// pending will occupy. Fails without the cold-path pooledBudgetAdmits call.
func TestFreeMemoryAdmitsColdModelChargesPool(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "resident", ActiveTokenBudgetMax: 10_000},
	}
	mkSnap := func(pendingAllModels int) routingSnapshot {
		return routingSnapshot{
			// Snapshot for a COLD model: no slot, no budget, model not loaded.
			pendingMaxTokensAllModels: pendingAllModels,
			pooledTokenBudget:         providerPooledTokenBudget(slots),
		}
	}
	if freeMemoryAdmits(mkSnap(10_000), 100, 1_900) {
		t.Fatal("cold request admitted into a pool fully pending to a resident model (cold path skipped the pooled gate)")
	}
	// Control: with 4k of the 10k pool pending, the 2k cold request fits.
	if !freeMemoryAdmits(mkSnap(4_000), 100, 1_900) {
		t.Fatal("cold request rejected although the pool has 6k of headroom")
	}
}

// TestPooledAdmissionColdModelDoubleSpendRealPath mirrors
// TestPooledAdmissionCoResidencyDoubleSpend with the target model COLD: gemma
// is advertised but has no backend slot, so its requests take the
// non-budget admission path. An in-gap burst to the resident gpt-oss slot
// consumes the whole shared pool; the cold gemma request must still be
// rejected. Fails without the cold-path pooled gate in freeMemoryAdmits.
func TestPooledAdmissionColdModelDoubleSpendRealPath(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild) // advertised, NOT loaded: no gemma slot
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p.mu.Unlock()

	// Burst the resident model: five requests × 2k tokens = the whole pool.
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
	// Cold gemma within the same gap: no slot to check, but the pool is fully
	// pending to gpt-oss — the post-load KV for this request does not exist.
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "victim", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
	}); got != nil {
		t.Fatalf("cold gemma admitted during the heartbeat gap — pool double-spend via the budget-less path (provider %q)", got.ID)
	}

	// Control: on a fresh box with only 4k pending, the cold request admits.
	reg2 := New(testLogger())
	p2 := makeSchedulerProvider(t, reg2, "shared-box-2", gptossBuild, 93)
	addAdvertisedModel(p2, gemmaBuild)
	p2.mu.Lock()
	p2.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p2.mu.Unlock()
	for i := 0; i < 2; i++ {
		if got := reg2.ReserveProvider(gptossBuild, &PendingRequest{
			RequestID: fmt.Sprintf("light-%d", i), Model: gptossBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
		}); got == nil {
			t.Fatalf("light burst request %d rejected", i)
		}
	}
	if got := reg2.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "fits", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
	}); got == nil {
		t.Fatal("cold gemma rejected although the pool has 6k of headroom (cold pooled gate over-rejecting)")
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
