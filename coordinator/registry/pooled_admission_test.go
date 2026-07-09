package registry

import (
	"fmt"
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestProviderPooledTokenBudgetClampsKVByteRate is the overflow regression: a
// slot reporting an absurd (unbounded) KVBytesPerToken multiplied by a normal
// token count wraps int64 to a NEGATIVE usedBytes/totalBytes, which breaks the
// byte-pool admission (a negative total either rejects everything or, with a
// negative left side, admits everything). The clamp caps the rate at
// maxKVBytesPerToken so all products and sums stay positive and admission fails
// closed. Fails without clampKVBytesPerToken in providerPooledTokenBudget.
func TestProviderPooledTokenBudgetClampsKVByteRate(t *testing.T) {
	const normalMax = 400_000
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: normalMax, ActiveTokenBudgetUsed: 200_000, KVBytesPerToken: math.MaxInt64 / 2},
	}
	pool := providerPooledTokenBudget(slots)
	if !pool.byteMode {
		t.Fatal("byteMode = false with a (clamped) positive KV rate")
	}
	if pool.usedBytes < 0 || pool.committedBytes < 0 || pool.totalBytes < 0 {
		t.Fatalf("byte pool overflowed to negative: used=%d committed=%d total=%d (KV rate not clamped)",
			pool.usedBytes, pool.committedBytes, pool.totalBytes)
	}
	if pool.totalBytes < pool.usedBytes {
		t.Fatalf("totalBytes %d < usedBytes %d (overflow)", pool.totalBytes, pool.usedBytes)
	}
	if got := pool.kvBytesPerToken["a"]; got != maxKVBytesPerToken {
		t.Fatalf("stored KV rate = %d, want clamp %d (raw absurd rate not clamped)", got, maxKVBytesPerToken)
	}
	// Admission must fail-closed for a request that overflows the pool, not
	// admit-everything off a wrapped negative total. Free headroom is
	// (400k − 200k) = 200k tokens at the clamped rate.
	snap := routingSnapshot{
		activeTokenBudgetMax: normalMax,
		kvBytesPerToken:      maxKVBytesPerToken,
		pendingBytesKnown:    true,
		pooledTokenBudget:    pool,
	}
	if pooledBudgetAdmits(snap, 10_000_000_000) {
		t.Fatal("admitted a 10B-token request into a finite byte pool (overflow admitted-everything)")
	}
	if !pooledBudgetAdmits(snap, 100_000) {
		t.Fatal("rejected a 100k-token request that fits the 200k-token byte headroom")
	}
}

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

// TestModelCapacitySnapshotPooledBudgetClamp: the public capacity feed
// (/v1/models[/capacity]) must not advertise per-slot budget headroom the
// pooled admission gate would reject. Co-resident slots each re-report the
// ONE shared 10k pool; after an in-gap 10k burst to gpt-oss, gemma's slot
// fields still read used=0/max=10k — but a gemma request would be rejected
// (pooledBudgetAdmits), so its row must report zero remaining budget and not
// be Ready. Fails without the pooledBudgetRemaining clamp in
// ModelCapacitySnapshot.
func TestModelCapacitySnapshotPooledBudgetClamp(t *testing.T) {
	build := func(pendingTokens int) *Registry {
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
		for i := 0; i < pendingTokens/2_000; i++ {
			if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
				RequestID: fmt.Sprintf("burst-%d", i), Model: gptossBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
			}); got == nil {
				t.Fatalf("burst request %d rejected", i)
			}
		}
		return reg
	}
	capsByModel := func(reg *Registry) map[string]ModelCapacity {
		out := make(map[string]ModelCapacity)
		for _, c := range reg.ModelCapacitySnapshot() {
			out[c.ModelID] = c
		}
		return out
	}

	// Pool fully pending to gpt-oss: gemma's stale slot (used 0 / max 10k)
	// must not surface as remaining budget or readiness.
	full := capsByModel(build(10_000))
	gemma, ok := full[gemmaBuild]
	if !ok {
		t.Fatalf("missing capacity row for %s", gemmaBuild)
	}
	if gemma.TokenBudgetRemaining != 0 {
		t.Fatalf("gemma token_budget_remaining = %d, want 0 (pool fully pending to co-resident gpt-oss)", gemma.TokenBudgetRemaining)
	}
	if gemma.Ready || gemma.CanAccept || gemma.RoutableProviders != 0 {
		t.Fatalf("gemma row = %+v, want not ready/routable with the shared pool exhausted", gemma)
	}

	// Control: 4k of the 10k pool pending → 6k remaining, still routable.
	part := capsByModel(build(4_000))
	gemma = part[gemmaBuild]
	if gemma.TokenBudgetRemaining != 6_000 {
		t.Fatalf("gemma token_budget_remaining = %d, want 6_000 (10k pool − 4k pending)", gemma.TokenBudgetRemaining)
	}
	if !gemma.Ready || gemma.RoutableProviders != 1 {
		t.Fatalf("gemma row = %+v, want ready/routable with 6k pooled headroom", gemma)
	}
}

// TestPooledByteTotalFromLiveUsedNotCommitted is the double-count regression
// (Finding 3): the byte pool total must be built from LIVE used bytes plus the
// shared free headroom — mirroring the token path (providerTokenBudget uses
// used+sharedFree) — NOT from committedBytes, which carries MaxTokensPotential
// as the pending de-dup baseline. A co-resident slot whose potential (0.4 GB)
// far exceeds its used (0) would otherwise inflate the 1 GB physical pool to
// 1.4 GB, letting an in-gap burst overcommit the box's real KV. Fails without
// the pool.usedBytes+sharedFreeBytes total in providerPooledTokenBudget.
func TestPooledByteTotalFromLiveUsedNotCommitted(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		// Big-KV slot with an active request whose POTENTIAL growth (4k tokens =
		// 0.4 GB) dwarfs its live used (0). Shared free = 10k × 100 kB = 1 GB.
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000, MaxTokensPotential: 4_000},
		// Small-KV co-resident sees the SAME 1 GB pool (100k × 10 kB).
		{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	}
	pool := providerPooledTokenBudget(slots)
	if !pool.byteMode {
		t.Fatal("byteMode = false with every budget slot reporting a KV rate")
	}
	if pool.usedBytes != 0 {
		t.Fatalf("usedBytes = %d, want 0 (no live used/queued on either slot)", pool.usedBytes)
	}
	if pool.committedBytes != 400_000_000 {
		t.Fatalf("committedBytes = %d, want 4e8 (0.4 GB de-dup baseline from MaxTokensPotential)", pool.committedBytes)
	}
	if pool.totalBytes != 1_000_000_000 {
		t.Fatalf("totalBytes = %d, want 1e9 (live used + shared free); committed potential must NOT inflate the pool total", pool.totalBytes)
	}

	// The admission gate must charge against the 1 GB physical pool, not the
	// inflated 1.4 GB. A 12k-token big-KV request is 1.2 GB — slot A's 0.4 GB of
	// potential is a de-dup baseline, not spare capacity, so it must be rejected.
	snap := routingSnapshot{
		activeTokenBudgetMax:      10_000,
		kvBytesPerToken:           100_000,
		pendingMaxBytesAllModels:  0,
		pendingMaxTokensAllModels: 0,
		pendingBytesKnown:         true,
		pooledTokenBudget:         pool,
	}
	if pooledBudgetAdmits(snap, 12_000) {
		t.Fatal("admitted 1.2 GB into a 1 GB byte pool — MaxTokensPotential double-counted as physical KV capacity")
	}
	// Control: 8k tokens = 0.8 GB genuinely fits the 1 GB pool.
	if !pooledBudgetAdmits(snap, 8_000) {
		t.Fatal("rejected 0.8 GB that fits the 1 GB byte pool (byte total under-counted)")
	}
}

// TestModelCapacitySnapshotByteModePooledClamp is the byte-unit capacity-feed
// regression (Finding 1): on a mixed-KV provider the public snapshot must
// clamp advertised budget in BYTES, matching pooledBudgetAdmits, not in tokens.
// A 0.9 GB small-KV burst leaves only 0.1 GB of the 1 GB pool — ~1k tokens for
// the 100 kB/token big-KV model — but token accounting reads 90k << the 100k
// token pool and would advertise ~10k gemma tokens the admission gate refuses.
// Fails without routing the snapshot through the byte-aware pooledRemainingTokens.
func TestModelCapacitySnapshotByteModePooledClamp(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	// gpt-oss small-KV: 10 kB/token → 100k-token view of the 1 GB pool.
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100_000
	p.BackendCapacity.Slots[0].KVBytesPerToken = 10_000
	// gemma big-KV: 100 kB/token → 10k-token view of the SAME 1 GB pool.
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 10_000,
		KVBytesPerToken:      100_000,
	})
	p.mu.Unlock()

	// Burst gpt-oss: nine × 10k tokens = 90k tokens = 0.9 GB pending, all inside
	// one heartbeat gap (slot used stays 0).
	for i := 0; i < 9; i++ {
		if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
			RequestID: fmt.Sprintf("burst-%d", i), Model: gptossBuild, EstimatedPromptTokens: 500, RequestedMaxTokens: 9_500,
		}); got == nil {
			t.Fatalf("burst request %d rejected; 0.9 GB must fit the 1 GB pool", i)
		}
	}

	caps := make(map[string]ModelCapacity)
	for _, c := range reg.ModelCapacitySnapshot() {
		caps[c.ModelID] = c
	}
	gemma, ok := caps[gemmaBuild]
	if !ok {
		t.Fatalf("missing capacity row for %s", gemmaBuild)
	}
	// Byte-accurate: 0.1 GB remaining ÷ 100 kB/token = 1_000 gemma tokens.
	// Token-mode (the bug) reports 100k pool − 90k pending = 10_000.
	if gemma.TokenBudgetRemaining != 1_000 {
		t.Fatalf("gemma token_budget_remaining = %d, want 1_000 (0.1 GB byte headroom); token-mode over-advertised the pool", gemma.TokenBudgetRemaining)
	}

	// Snapshot verdict must match the admission gate: a 3k-token (0.3 GB) gemma
	// request does NOT fit the 0.1 GB byte headroom, so ReserveProvider rejects.
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "probe", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 2_900,
	}); got != nil {
		t.Fatalf("gemma admitted 0.3 GB into 0.1 GB byte headroom (snapshot/gate disagree; provider %q)", got.ID)
	}
}

// TestPooledColdUnknownKVChargedInBytes is the cold unknown-KV regression: on a
// byte-reconstructable mixed-KV box, a COLD request (its own model has no
// resident slot, so snap.kvBytesPerToken == 0) must be priced CONSERVATIVELY in
// bytes at the bounded unknown-model default, NOT collapse to token accounting
// or borrow a rate that only describes resident models.
func TestPooledColdUnknownKVChargedInBytes(t *testing.T) {
	t.Run("mixed_kv_cold_priced_at_default_rate", func(t *testing.T) {
		slots := []protocol.BackendSlotCapacity{
			{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},   // 1 GB view
			{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000}, // same 1 GB
		}
		pool := providerPooledTokenBudget(slots)
		if !pool.byteMode {
			t.Fatal("pool byteMode = false, want true")
		}
		if got := resolvedPooledKVBytesPerToken(pool, 0); got != kvCacheBytesPerToken {
			t.Fatalf("resolved cold KV rate = %d, want conservative default %d", got, kvCacheBytesPerToken)
		}
		cold := routingSnapshot{
			kvBytesPerToken:   0, // cold/absent slot
			pendingBytesKnown: true,
			pooledTokenBudget: pool,
		}
		// 50k tokens: token fallback would admit (50k <= 100k token pool), but
		// conservative byte pricing is far beyond the 1 GB pool.
		if pooledBudgetAdmits(cold, 50_000) {
			t.Fatal("cold unknown-KV request admitted via token/resident-rate fallback")
		}
		// Control: 2k tokens at the default rate remain below 1 GB.
		if !pooledBudgetAdmits(cold, 2_000) {
			t.Fatal("cold request rejected although its conservative byte charge fits the pool")
		}
		wantRemaining := pool.totalBytes / kvCacheBytesPerToken
		if rem := pooledRemainingTokens(pool, 0, 0, true, 0); rem != wantRemaining {
			t.Fatalf("cold pooledRemainingTokens = %d, want %d (byte pool / default rate)", rem, wantRemaining)
		}
	})

	// A known resident model still uses its reported rate, so its established
	// byte/token boundary is unchanged by the cold-model default.
	t.Run("known_model_keeps_reported_rate_boundary", func(t *testing.T) {
		pool := providerPooledTokenBudget([]protocol.BackendSlotCapacity{
			{Model: "m", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 50_000},
		})
		known := routingSnapshot{kvBytesPerToken: 50_000, pendingBytesKnown: true, pooledTokenBudget: pool}
		if !pooledBudgetAdmits(known, 10_000) {
			t.Fatal("known request at the exact 10k boundary rejected")
		}
		if pooledBudgetAdmits(known, 10_001) {
			t.Fatal("known request past the 10k boundary admitted")
		}
	})
}

// TestPooledFirstColdRequestUsesConservativeDefault pins the unknown-model
// boundary: resident slots only reveal THEIR KV rates, so the largest resident
// rate is not a safe price for a first request to a cold model. A box with only
// a cheap 10 kB/token resident model has a 1 GB pool; a 3k-token cold request
// fits at that resident rate but exceeds the pool at the bounded conservative
// default used for an unknown model.
func TestPooledFirstColdRequestUsesConservativeDefault(t *testing.T) {
	pool := providerPooledTokenBudget([]protocol.BackendSlotCapacity{
		{Model: "resident-small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	})
	snap := routingSnapshot{
		kvBytesPerToken:   0, // first request: cold model has no slot-reported rate
		pendingBytesKnown: true,
		pooledTokenBudget: pool,
	}

	if pooledBudgetAdmits(snap, 3_000) {
		t.Fatal("first cold request priced at resident-only KV max instead of the conservative unknown-model default")
	}
	wantRemaining := pool.totalBytes / kvCacheBytesPerToken
	if got := pooledRemainingTokens(pool, 0, 0, true, 0); got != wantRemaining {
		t.Fatalf("cold pooled remaining = %d, want %d from conservative default rate", got, wantRemaining)
	}
}

// TestPooledPendingColdRequestKeepsByteAccounting pins the second-request
// boundary. Once an unknown cold request is pending, its missing resident slot
// must be charged at the same conservative default rather than disabling byte
// accounting for the entire provider. Otherwise a subsequent resident request
// falls back to the much looser token pool and double-spends physical KV bytes.
func TestPooledPendingColdRequestKeepsByteAccounting(t *testing.T) {
	const residentRate = int64(10_000)
	p := &Provider{
		BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{
			{Model: "resident-small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: residentRate},
		}},
		pendingReqs: map[string]*PendingRequest{
			"cold": {
				RequestID:          "cold",
				Model:              "cold-unknown-kv",
				RequestedMaxTokens: 2_100,
			},
		},
	}

	var snap routingSnapshot
	fillSnapshotPendingAndPool(&snap, p, "resident-small-kv")
	snap.kvBytesPerToken = residentRate

	wantPendingBytes := int64(2_100) * kvCacheBytesPerToken
	if !snap.pendingBytesKnown {
		t.Error("cold pending request disabled provider byte accounting")
	}
	if snap.pendingMaxBytesAllModels != wantPendingBytes {
		t.Errorf("cold pending bytes = %d, want %d at conservative default rate", snap.pendingMaxBytesAllModels, wantPendingBytes)
	}
	if pooledBudgetAdmits(snap, 20_000) {
		t.Error("subsequent resident request admitted via token fallback after cold pending request consumed byte headroom")
	}
	wantRemaining := (snap.pooledTokenBudget.totalBytes - wantPendingBytes) / residentRate
	if got := pooledRemainingTokens(
		snap.pooledTokenBudget,
		snap.pendingMaxTokensAllModels,
		snap.pendingMaxBytesAllModels,
		snap.pendingBytesKnown,
		snap.kvBytesPerToken,
	); got != wantRemaining {
		t.Errorf("resident pooled remaining = %d, want %d after default-priced cold pending request", got, wantRemaining)
	}

	overflowTokens := int64(math.MaxInt64/kvCacheBytesPerToken + 1)
	if got := addPooledKVByteCharge(0, overflowTokens, resolvedPooledKVBytesPerToken(snap.pooledTokenBudget, 0)); got != math.MaxInt64 {
		t.Errorf("overflowing cold pending charge = %d, want saturated MaxInt64", got)
	}
}

// TestPooledRemainingTokensMatchesAdmits pins the equivalence the capacity feed
// relies on: pooledBudgetAdmits(snap, n) admits IFF n <= pooledRemainingTokens(
// pool, …, snap.kvBytesPerToken), across the byte path (known rate), the byte
// COLD path (rate 0 -> bounded default substitution), token mode, and the
// pending-unknown fall-through. Both must apply the SAME rate resolver.
func TestPooledRemainingTokensMatchesAdmits(t *testing.T) {
	bytePool := providerPooledTokenBudget([]protocol.BackendSlotCapacity{
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	})
	tokenPool := providerPooledTokenBudget([]protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000},
		{Model: "b", ActiveTokenBudgetMax: 10_000},
	})
	cases := []struct {
		name string
		snap routingSnapshot
	}{
		{"byte_known_rate", routingSnapshot{
			kvBytesPerToken: 100_000, pendingBytesKnown: true,
			pendingMaxTokensAllModels: 20_000, pendingMaxBytesAllModels: 20_000 * 10_000,
			pooledTokenBudget: bytePool,
		}},
		{"byte_cold_rate", routingSnapshot{
			kvBytesPerToken: 0, pendingBytesKnown: true,
			pendingMaxTokensAllModels: 10_000, pendingMaxBytesAllModels: 10_000 * 10_000,
			pooledTokenBudget: bytePool,
		}},
		{"token_mode", routingSnapshot{
			pendingMaxTokensAllModels: 4_000,
			pooledTokenBudget:         tokenPool,
		}},
		{"byte_pending_unknown_falls_to_token", routingSnapshot{
			kvBytesPerToken: 100_000, pendingBytesKnown: false,
			pendingMaxTokensAllModels: 5_000,
			pooledTokenBudget:         bytePool,
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rem := pooledRemainingTokens(
				tc.snap.pooledTokenBudget,
				tc.snap.pendingMaxTokensAllModels,
				tc.snap.pendingMaxBytesAllModels,
				tc.snap.pendingBytesKnown,
				tc.snap.kvBytesPerToken,
			)
			for n := int64(1); n <= rem+50; n++ {
				if admits, want := pooledBudgetAdmits(tc.snap, n), n <= rem; admits != want {
					t.Fatalf("n=%d: pooledBudgetAdmits=%v, but (n<=rem=%d)=%v", n, admits, rem, want)
				}
			}
		})
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
