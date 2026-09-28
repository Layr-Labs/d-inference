package registry

import (
	"fmt"
	"math"
	"sync"
	"testing"
	"time"

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
	if got := pool.kvRateFor("a"); got != maxKVBytesPerToken {
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
	if pooledBudgetAdmits(snapPtr(snap), 10_000_000_000) {
		t.Fatal("admitted a 10B-token request into a finite byte pool (overflow admitted-everything)")
	}
	if !pooledBudgetAdmits(snapPtr(snap), 100_000) {
		t.Fatal("rejected a 100k-token request that fits the 200k-token byte headroom")
	}
}

// TestPooledKnownZeroBudgetRejects distinguishes a modern Engine V2 slot whose
// positive KV rate makes a zero budget authoritative from a legacy slot that
// reports neither field. A live fleet clamp can truthfully drive the v2 token
// budget to zero while KVBytesPerToken remains known; treating total==0 as the
// legacy "no constraint" sentinel would fail open.
func TestPooledKnownZeroBudgetRejects(t *testing.T) {
	pool := providerPooledTokenBudget([]protocol.BackendSlotCapacity{
		{Model: "known-full", ActiveTokenBudgetMax: 0, KVBytesPerToken: 800_000},
	})
	snap := routingSnapshot{
		kvBytesPerToken:   800_000,
		pendingBytesKnown: true,
		pooledTokenBudget: pool,
	}
	if pooledBudgetAdmits(snapPtr(snap), 1) {
		t.Fatal("known-zero Engine V2 budget admitted a request as if it were an unconstrained legacy slot")
	}
	if got := pooledRemainingTokens(pool, 0, 0, true, 800_000); got != 0 {
		t.Fatalf("known-zero pooled remaining = %d, want 0", got)
	}

	legacy := providerPooledTokenBudget([]protocol.BackendSlotCapacity{{Model: "legacy"}})
	legacySnap := routingSnapshot{pooledTokenBudget: legacy}
	if !pooledBudgetAdmits(snapPtr(legacySnap), 1) {
		t.Fatal("legacy slot with no budget or KV rate became constrained")
	}
	if got := pooledRemainingTokens(legacy, 0, 0, false, 0); got != -1 {
		t.Fatalf("legacy pooled remaining = %d, want -1 no-constraint sentinel", got)
	}
}

// TestPooledZeroBudgetResidentRateStaysSymmetric pins the mixed-slot case. A
// resident v2 model can report a positive KV rate with a zero budget after the
// live fleet clamp. Its rate must remain available even though the slot adds no
// budget: pending aggregation, incoming admission, and ModelCapacitySnapshot
// must all price that model at the same reported rate.
func TestPooledZeroBudgetResidentRateStaysSymmetric(t *testing.T) {
	const (
		budgetedRate  = int64(10_000)
		knownZeroRate = int64(800_000)
	)
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "mixed-known-zero", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].State = "running"
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100_000
	p.BackendCapacity.Slots[0].KVBytesPerToken = budgetedRate
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 0,
		KVBytesPerToken:      knownZeroRate,
	})
	pool := providerPooledTokenBudget(p.BackendCapacity.Slots)
	p.mu.Unlock()

	if got := pool.kvRateFor(gemmaBuild); got != knownZeroRate {
		t.Fatalf("zero-budget resident KV rate = %d, want reported %d", got, knownZeroRate)
	}

	// Pending work for the zero-budget resident must use its real rate, not the
	// 400 kB/token unknown-model default.
	p.mu.Lock()
	p.pendingReqs["known-zero-pending"] = &PendingRequest{
		RequestID:          "known-zero-pending",
		Model:              gemmaBuild,
		RequestedMaxTokens: 1,
	}
	var pendingSnap routingSnapshot
	fillSnapshotPendingAndPool(&pendingSnap, p, gemmaBuild)
	delete(p.pendingReqs, "known-zero-pending")
	p.mu.Unlock()
	if !pendingSnap.pendingBytesKnown {
		t.Fatal("zero-budget resident disabled byte accounting")
	}
	if got := pendingSnap.pendingMaxBytesAllModels; got != knownZeroRate {
		t.Fatalf("zero-budget resident pending bytes = %d, want reported rate %d", got, knownZeroRate)
	}

	capacityForGemma := func() ModelCapacity {
		t.Helper()
		for _, capacity := range reg.ModelCapacitySnapshot() {
			if capacity.ModelID == gemmaBuild {
				return capacity
			}
		}
		t.Fatalf("missing capacity row for %s", gemmaBuild)
		return ModelCapacity{}
	}

	// The model-local zero is authoritative even while the co-resident model
	// still exposes its full grant. The known-zero model must reject and
	// stay non-routable; the positive-budget model remains usable.
	if gemma := capacityForGemma(); gemma.Ready || gemma.RoutableProviders != 0 {
		t.Fatalf("known-zero model with abundant pooled headroom = %+v, want not ready/routable", gemma)
	}
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "known-zero-probe", Model: gemmaBuild, RequestedMaxTokens: 1,
	}); got != nil {
		t.Fatalf("known-zero model admitted from co-resident pooled headroom on provider %q", got.ID)
	}
	if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
		RequestID: "positive-budget-probe", Model: gptossBuild, RequestedMaxTokens: 1,
	}); got == nil {
		t.Fatal("positive-budget co-resident was blocked by another model's known-zero budget")
	} else {
		got.RemovePending("positive-budget-probe")
	}

	// Leave 500 kB of the 1 GB pool. That fits one token only under the
	// incorrect 400 kB default; the reported 800 kB rate yields zero capacity.
	p.mu.Lock()
	p.pendingReqs["small-kv-burst"] = &PendingRequest{
		RequestID:          "small-kv-burst",
		Model:              gptossBuild,
		RequestedMaxTokens: 99_950,
	}
	p.mu.Unlock()

	gemma := capacityForGemma()
	if gemma.Ready || gemma.RoutableProviders != 0 {
		t.Fatalf("zero-budget resident capacity = %+v, want not ready/routable with less than one reported-rate token left", gemma)
	}
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "probe", Model: gemmaBuild, RequestedMaxTokens: 1,
	}); got != nil {
		t.Fatalf("zero-budget resident admitted one 800 kB token into 500 kB headroom on provider %q", got.ID)
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
			name: "two_slots_private_grants_add",
			// Each max is that model's private engine grant, so the box-wide
			// ceiling is 10k + 9k; live use sums to 3k.
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: 2_000},
				{Model: "b", ActiveTokenBudgetMax: 9_000, ActiveTokenBudgetUsed: 1_000},
			},
			used:      3_000,
			committed: 3_000,
			total:     19_000,
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
// driven through the REAL reservation path: two resident models hold private
// 10k grants (a 20k box), and a burst to a COLD third model is admitted
// against that pool inside one heartbeat gap. Loading the cold model will
// re-slice the grants, but until the next heartbeat the resident slots still
// advertise their full 10k — so the per-slot check alone would admit a
// resident request into KV the cold burst already owns. The pooled check must
// charge the cold pending against the resident request. Fails without the
// pooledBudgetAdmits call in freeMemoryAdmits.
func TestPooledAdmissionCoResidencyDoubleSpend(t *testing.T) {
	const coldBuild = "pooled-cold-model"
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	addAdvertisedModel(p, coldBuild) // advertised, NOT loaded: no slot
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 10_000,
	})
	p.mu.Unlock()

	// Burst the cold model: seven requests × (100 prompt + 1_900 max) =
	// 14_000 of the 20_000-token pool, all inside one heartbeat gap.
	for i := 0; i < 7; i++ {
		pr := &PendingRequest{
			RequestID:             fmt.Sprintf("burst-%d", i),
			Model:                 coldBuild,
			EstimatedPromptTokens: 100,
			RequestedMaxTokens:    1_900,
		}
		if got := reg.ReserveProvider(coldBuild, pr); got == nil {
			t.Fatalf("cold burst request %d rejected; 7×2k must fit the 20k pool", i)
		}
	}

	// Gemma within the same gap: its slot still reads max 10_000 / used 0, so
	// the per-slot check admits 8k — but only 20k − 14k = 6k of the pool is
	// left. Must be rejected.
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "victim", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 7_900,
	}); got != nil {
		t.Fatalf("gemma admitted 8k during the heartbeat gap — double-spend of the cold burst's pool share (provider %q)", got.ID)
	}
	// Control: a 6k gemma request fits the remaining pool exactly.
	if got := reg.ReserveProvider(gemmaBuild, &PendingRequest{
		RequestID: "fits", Model: gemmaBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 5_900,
	}); got == nil {
		t.Fatal("gemma rejected although 6k of the pool remains (pooled gate over-rejecting)")
	}
}

// TestConcurrentReservationScansCommitPooledBudgetAtomically proves the
// production primary path can scan different models concurrently without
// double-spending one provider's cross-model token pool. Two COLD models (no
// slot, so only the pooled gate bounds them) race for one resident 3k grant.
// Both scans rendezvous after seeing the same empty heartbeat snapshot; the
// short serialized commit must admit exactly one 2k request.
func TestConcurrentReservationScansCommitPooledBudgetAtomically(t *testing.T) {
	const coldA, coldB = "pooled-cold-a", "pooled-cold-b"
	build := func(grant int64) *Registry {
		reg := New(testLogger())
		p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
		addAdvertisedModel(p, coldA)
		addAdvertisedModel(p, coldB)
		p.mu.Lock()
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = grant
		p.mu.Unlock()
		return reg
	}
	reserve := func(reg *Registry, model, id string) *Provider {
		provider, _, _ := reg.ReserveProviderWithPlan(model, &PendingRequest{
			RequestID:             id,
			Model:                 model,
			EstimatedPromptTokens: 100,
			RequestedMaxTokens:    1_900,
		})
		return provider
	}

	// Control: with a 10k grant both cold models fit, so nothing but the pool
	// separates them from a double admission in the racing case below.
	control := build(10_000)
	if reserve(control, coldA, "control-a") == nil || reserve(control, coldB, "control-b") == nil {
		t.Fatal("two 2k cold requests must both fit a 10k pool")
	}

	reg := build(3_000)

	arrived := make(chan string, 2)
	release := make(chan struct{})
	var releaseOnce sync.Once
	releaseScans := func() { releaseOnce.Do(func() { close(release) }) }
	defer releaseScans()
	var seenMu sync.Mutex
	seen := make(map[string]bool, 2)
	reg.reservationAfterScan = func(model string) {
		seenMu.Lock()
		first := !seen[model]
		seen[model] = true
		seenMu.Unlock()
		if !first {
			return
		}
		arrived <- model
		<-release
	}

	type result struct {
		requestID string
		provider  *Provider
	}
	results := make(chan result, 2)
	start := make(chan struct{})
	for i, model := range []string{coldA, coldB} {
		go func() {
			<-start
			requestID := fmt.Sprintf("concurrent-%d", i)
			results <- result{requestID: requestID, provider: reserve(reg, model, requestID)}
		}()
	}
	close(start)

	entered := make(map[string]bool, 2)
	for len(entered) < 2 {
		select {
		case model := <-arrived:
			entered[model] = true
		case <-time.After(2 * time.Second):
			releaseScans()
			t.Fatalf("reservation scans serialized before commit; entered=%v", entered)
		}
	}
	releaseScans()
	reservations := make([]result, 0, 2)
	admitted := 0
	for range 2 {
		res := <-results
		reservations = append(reservations, res)
		if res.provider != nil {
			admitted++
		}
	}
	for _, res := range reservations {
		if res.provider != nil {
			res.provider.RemovePending(res.requestID)
		}
	}
	if admitted != 1 {
		t.Fatalf("concurrent cross-model reservations admitted %d requests, want exactly 1", admitted)
	}
}

// TestPooledAdmissionPrivateGrantsPreserveCrossModelCapacity pins that each
// slot max is a private engine grant: two 10k slots expose 20k aggregate
// capacity, so both models admit 8k (16k in total, more than either grant),
// while each model still has its own 10k limit. It is also the pooled gate's
// non-regression control: a co-resident request with real headroom left is
// admitted.
func TestPooledAdmissionPrivateGrantsPreserveCrossModelCapacity(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "private-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p.BackendCapacity.Slots[0].KVBytesPerToken = 100_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 10_000,
		KVBytesPerToken:      100_000,
	})
	p.mu.Unlock()
	reserve := func(model, id string, tokens int) *Provider {
		return reg.ReserveProvider(model, &PendingRequest{
			RequestID:             id,
			Model:                 model,
			EstimatedPromptTokens: 100,
			RequestedMaxTokens:    tokens - 100,
		})
	}

	if got := reserve(gptossBuild, "private-a", 8_000); got == nil {
		t.Fatal("model A rejected despite fitting its private 10k grant")
	}
	if got := reserve(gemmaBuild, "private-b", 8_000); got == nil {
		t.Fatal("model B rejected: private 10k grants were collapsed into one shared pool")
	}
	if got := reserve(gemmaBuild, "private-b-overflow", 3_000); got != nil {
		t.Fatalf("model B exceeded its private 10k grant on provider %q", got.ID)
	}
}

func TestPrivateGrantPoolUsesCeilingsWhenLiveUseExceedsReslice(t *testing.T) {
	const rate int64 = 100_000
	tests := []struct {
		name       string
		slots      []protocol.BackendSlotCapacity
		wantUsed   int64
		wantTotal  int64
		wantRemain int64
	}{
		{
			name: "shrunken slot remains over its new ceiling",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 5_000, ActiveTokenBudgetUsed: 8_000, KVBytesPerToken: rate},
				{Model: "b", ActiveTokenBudgetMax: 5_000, KVBytesPerToken: rate},
			},
			wantUsed:   8_000,
			wantTotal:  10_000,
			wantRemain: 2_000,
		},
		{
			name: "known-zero slot live use drains a co-resident grant",
			slots: []protocol.BackendSlotCapacity{
				{Model: "a", ActiveTokenBudgetMax: 0, ActiveTokenBudgetUsed: 3_000, KVBytesPerToken: rate},
				{Model: "b", ActiveTokenBudgetMax: 5_000, KVBytesPerToken: rate},
			},
			wantUsed:   3_000,
			wantTotal:  5_000,
			wantRemain: 2_000,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			pool := providerPooledTokenBudget(tc.slots)
			if pool.used != tc.wantUsed || pool.total != tc.wantTotal {
				t.Fatalf("token pool = {used:%d total:%d}, want {%d %d}",
					pool.used, pool.total, tc.wantUsed, tc.wantTotal)
			}
			if pool.usedBytes != tc.wantUsed*rate || pool.totalBytes != tc.wantTotal*rate {
				t.Fatalf("byte pool = {used:%d total:%d}, want {%d %d}",
					pool.usedBytes, pool.totalBytes, tc.wantUsed*rate, tc.wantTotal*rate)
			}
			if got := pooledRemainingTokens(pool, 0, 0, true, rate); got != tc.wantRemain {
				t.Fatalf("remaining = %d, want %d", got, tc.wantRemain)
			}
			snap := routingSnapshot{
				kvBytesPerToken:   rate,
				pendingBytesKnown: true,
				pooledTokenBudget: pool,
			}
			if !pooledBudgetAdmits(snapPtr(snap), tc.wantRemain) {
				t.Fatalf("rejected exact remaining capacity %d", tc.wantRemain)
			}
			if pooledBudgetAdmits(snapPtr(snap), tc.wantRemain+1) {
				t.Fatalf("admitted past remaining capacity %d", tc.wantRemain)
			}
		})
	}
}

func TestPrivateGrantPoolSaturatesUsedBudgetAddition(t *testing.T) {
	pool := providerPooledTokenBudget([]protocol.BackendSlotCapacity{{
		Model:                 "overflow",
		ActiveTokenBudgetMax:  math.MaxInt64,
		ActiveTokenBudgetUsed: math.MaxInt64,
		QueuedTokenBudget:     1,
		KVBytesPerToken:       1,
	}})
	if pool.used != math.MaxInt64 || pool.usedBytes != math.MaxInt64 {
		t.Fatalf("overflowed used budget = {tokens:%d bytes:%d}, want saturated MaxInt64",
			pool.used, pool.usedBytes)
	}
	if pooledBudgetAdmits(snapPtr(routingSnapshot{
		kvBytesPerToken:   1,
		pendingBytesKnown: true,
		pooledTokenBudget: pool,
	}),

		1) {
		t.Fatal("overflowed live use left invented private-grant headroom")
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
	if !freeMemoryAdmits(snapPtr(mkSnap(7_000)), 0, 5_500) {
		t.Fatal("request at the exact old boundary (5_500) rejected — pooled check changed single-model behavior")
	}
	if freeMemoryAdmits(snapPtr(mkSnap(7_000)), 0, 5_501) {
		t.Fatal("request past the old boundary (5_501) admitted — budget admission loosened")
	}
}

// TestFreeMemoryAdmitsPooledRejectsGapDoubleSpend is the pure-function version
// of the double-spend regression (fails without the pooledBudgetAdmits call):
// model B's own 10k grant admits, but coordinator-pending work for a cold
// co-model has consumed most of the 20k box-wide pool.
func TestFreeMemoryAdmitsPooledRejectsGapDoubleSpend(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000},
		{Model: "b", ActiveTokenBudgetMax: 10_000},
	}
	snap := routingSnapshot{
		// Snapshot for model B: no same-model pending, stale heartbeat (used 0).
		pendingMaxTokens:          0,
		pendingMaxTokensAllModels: 19_000, // a cold co-model's in-gap burst
		activeTokenBudgetMax:      10_000,
		pooledTokenBudget:         providerPooledTokenBudget(slots),
	}
	if freeMemoryAdmits(snapPtr(snap), 100, 1_900) {
		t.Fatal("admitted 2k tokens into a 20k pool with 19k already pending to a co-model (per-slot double-spend)")
	}
	// Same snapshot with 14k pending across models → 6k headroom admits.
	snap.pendingMaxTokensAllModels = 14_000
	if !freeMemoryAdmits(snapPtr(snap), 100, 1_900) {
		t.Fatal("rejected 2k tokens although the pool has 6k of headroom")
	}
}

// TestProviderPooledTokenBudgetByteNormalization pins the byte-space
// reconstruction: per-slot token quantities scale by that slot's own
// KVBytesPerToken, the grants add in bytes, and a single budget slot without a
// KV rate disables byte mode for the whole pool (legacy provider build).
func TestProviderPooledTokenBudgetByteNormalization(t *testing.T) {
	// Big-KV model A: 10k-token grant × 100 kB/token = 1 GB.
	// Small-KV model B: 100k-token grant × 10 kB/token = 1 GB.
	slots := []protocol.BackendSlotCapacity{
		{Model: "a", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "b", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000},
	}
	pool := providerPooledTokenBudget(slots)
	if !pool.byteMode {
		t.Fatal("byteMode = false with every budget slot reporting a KV rate")
	}
	if pool.totalBytes != 2_000_000_000 || pool.usedBytes != 0 || pool.committedBytes != 0 {
		t.Fatalf("byte pool = {used:%d committed:%d total:%d}, want {0 0 2e9} (1 GB + 1 GB of grants)",
			pool.usedBytes, pool.committedBytes, pool.totalBytes)
	}
	// Token space adds 10k + 100k tokens that cost 10× different amounts —
	// the unit mixing byte mode exists to correct.
	if pool.total != 110_000 {
		t.Fatalf("token pool total = %d, want 110_000", pool.total)
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
// token counts are not a common unit. A re-slice shrank the big-KV model's
// grant to 100 tokens (10 MB) while it still holds 500 tokens (50 MB) live, so
// of the 110 MB of grants only 60 MB remains — 6k tokens for the small-KV
// model (10 kB/token). Token accounting reads 10_100 − 500 = 9_600 tokens
// free and would admit an 8k small-KV request (80 MB) the box cannot hold.
// Fails without the byte-normalized branch in pooledBudgetAdmits.
func TestFreeMemoryAdmitsByteNormalizedHeterogeneousKV(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "big-kv", ActiveTokenBudgetMax: 100, ActiveTokenBudgetUsed: 500, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 10_000},
	}
	snap := routingSnapshot{
		// Snapshot for the small-KV model: its own slot is idle.
		activeTokenBudgetMax: 10_000,
		kvBytesPerToken:      10_000,
		pendingBytesKnown:    true,
		pooledTokenBudget:    providerPooledTokenBudget(slots),
	}
	// 8k small-KV tokens = 80 MB > 60 MB of byte headroom.
	if freeMemoryAdmits(snapPtr(snap), 100, 7_900) {
		t.Fatal("admitted 80 MB of small-KV request into 60 MB of byte headroom (token/byte unit confusion)")
	}
	// Control: 5k small-KV tokens = 50 MB ≤ 60 MB.
	if !freeMemoryAdmits(snapPtr(snap), 100, 4_900) {
		t.Fatal("rejected a request although the byte pool has 60 MB of headroom (byte gate over-rejecting)")
	}
}

// TestFreeMemoryAdmitsByteModeCorrectsTokenOverReject is the reverse sanity
// case: a re-slice left the small-KV model holding 90k live tokens (0.9 GB)
// against a 10k-token (0.1 GB) grant. In tokens the box reads 20k of grants
// against 90k used — no headroom at all — but in bytes it is 1.1 GB of grants
// against 0.9 GB used, so a 1k-token (0.1 GB) big-KV request genuinely fits.
// With byte mode the check admits; token accounting wrongly rejects.
func TestFreeMemoryAdmitsByteModeCorrectsTokenOverReject(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},
		{Model: "small-kv", ActiveTokenBudgetMax: 10_000, ActiveTokenBudgetUsed: 90_000, KVBytesPerToken: 10_000},
	}
	snap := routingSnapshot{
		// Snapshot for the big-KV model.
		activeTokenBudgetMax: 10_000,
		kvBytesPerToken:      100_000,
		pendingBytesKnown:    true,
		pooledTokenBudget:    providerPooledTokenBudget(slots),
	}
	if !pooledBudgetAdmits(snapPtr(snap), 1_000) {
		t.Fatal("rejected 0.1 GB into 0.2 GB of byte headroom (token-unit over-rejection not corrected)")
	}
	if pooledBudgetAdmits(snapPtr(snap), 2_001) {
		t.Fatal("admitted past the 0.2 GB byte headroom")
	}
}

// TestPooledAdmissionByteDoubleSpendRealPath drives the heterogeneous-KV
// double-spend through the REAL reservation path: a re-slice shrank gemma's
// (100 kB/token) grant below its live use, so the 110 MB of grants has only
// 60 MB left. A gpt-oss (10 kB/token) request of 8k tokens fits its own 10k
// grant and 9_600 free tokens in token space, but 80 MB does NOT fit 60 MB of
// byte headroom. Fails without byte normalization.
func TestPooledAdmissionByteDoubleSpendRealPath(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	// gpt-oss: 10 kB/token, 10k-token grant = 100 MB.
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p.BackendCapacity.Slots[0].KVBytesPerToken = 10_000
	// gemma: 100 kB/token, grant shrunk to 100 tokens (10 MB) while 500 tokens
	// (50 MB) are still live.
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                 gemmaBuild,
		State:                 "running",
		ActiveTokenBudgetMax:  100,
		ActiveTokenBudgetUsed: 500,
		KVBytesPerToken:       100_000,
	})
	p.mu.Unlock()

	if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
		RequestID: "victim", Model: gptossBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 7_900,
	}); got != nil {
		t.Fatalf("gpt-oss admitted 80 MB into 60 MB of byte headroom — token-unit accounting double-spent the byte pool (provider %q)", got.ID)
	}
	// Control: 5k tokens (50 MB) fit.
	if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
		RequestID: "fits", Model: gptossBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 4_900,
	}); got == nil {
		t.Fatal("gpt-oss rejected although its 50 MB fits the 60 MB of byte headroom")
	}
}

// TestFreeMemoryAdmitsColdModelChargesPool is the cold-slot pooled-gate
// regression (pure-function form): the target model reports NO budget slot
// (activeTokenBudgetMax == 0, not loaded here), so it skips the budget branch
// entirely — but a resident co-model's slot reports its grant, and the
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
	if freeMemoryAdmits(snapPtr(mkSnap(10_000)), 100, 1_900) {
		t.Fatal("cold request admitted into a pool fully pending to a resident model (cold path skipped the pooled gate)")
	}
	// Control: with 4k of the 10k pool pending, the 2k cold request fits.
	if !freeMemoryAdmits(snapPtr(mkSnap(4_000)), 100, 1_900) {
		t.Fatal("cold request rejected although the pool has 6k of headroom")
	}
}

// TestPooledAdmissionColdModelDoubleSpendRealPath is the reverse of
// TestPooledAdmissionCoResidencyDoubleSpend: gemma is advertised but has no
// backend slot, so its requests take the non-budget admission path. An in-gap
// burst to the resident gpt-oss slot consumes the whole pool; the cold gemma
// request must still be rejected. Fails without the cold-path pooled gate in
// freeMemoryAdmits.
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
// pooled admission gate would reject. Two resident slots hold private 10k
// grants; after an in-gap burst to a COLD co-model consumes the whole 20k
// pool, gemma's slot fields still read used=0/max=10k — but a gemma request
// would be rejected (pooledBudgetAdmits), so its row must report zero
// remaining budget and not be Ready. Fails without the pooledBudgetRemaining
// clamp in ModelCapacitySnapshot.
func TestModelCapacitySnapshotPooledBudgetClamp(t *testing.T) {
	const coldBuild = "pooled-cold-model"
	build := func(pendingTokens int) *Registry {
		reg := New(testLogger())
		p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
		addAdvertisedModel(p, gemmaBuild)
		addAdvertisedModel(p, coldBuild)
		p.mu.Lock()
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
		p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
			Model:                gemmaBuild,
			State:                "running",
			ActiveTokenBudgetMax: 10_000,
		})
		p.mu.Unlock()
		for i := 0; i < pendingTokens/2_000; i++ {
			if got := reg.ReserveProvider(coldBuild, &PendingRequest{
				RequestID: fmt.Sprintf("burst-%d", i), Model: coldBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 1_900,
			}); got == nil {
				t.Fatalf("cold burst request %d rejected", i)
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

	// Pool fully pending to the cold co-model: gemma's stale slot (used 0 /
	// max 10k) must not surface as remaining budget or readiness.
	full := capsByModel(build(20_000))
	gemma, ok := full[gemmaBuild]
	if !ok {
		t.Fatalf("missing capacity row for %s", gemmaBuild)
	}
	if gemma.TokenBudgetRemaining != 0 {
		t.Fatalf("gemma token_budget_remaining = %d, want 0 (pool fully pending to the cold co-model)", gemma.TokenBudgetRemaining)
	}
	if gemma.Ready || gemma.CanAccept || gemma.RoutableProviders != 0 {
		t.Fatalf("gemma row = %+v, want not ready/routable with the pool exhausted", gemma)
	}

	// Control: 14k of the 20k pool pending → 6k remaining, still routable.
	part := capsByModel(build(14_000))
	gemma = part[gemmaBuild]
	if gemma.TokenBudgetRemaining != 6_000 {
		t.Fatalf("gemma token_budget_remaining = %d, want 6_000 (20k pool − 14k pending)", gemma.TokenBudgetRemaining)
	}
	if !gemma.Ready || gemma.RoutableProviders != 1 {
		t.Fatalf("gemma row = %+v, want ready/routable with 6k pooled headroom", gemma)
	}
}

// TestPooledByteTotalFromLiveUsedNotCommitted is the double-count regression
// (Finding 3): the byte pool total must be the sum of the byte grants —
// mirroring the token path (providerTokenBudget sums the grants) — NOT be
// built from committedBytes, which carries MaxTokensPotential as the pending
// de-dup baseline. A slot whose potential (0.4 GB) far exceeds its used (0)
// would otherwise inflate the 2 GB physical pool to 2.4 GB, letting an in-gap
// burst overcommit the box's real KV.
func TestPooledByteTotalFromLiveUsedNotCommitted(t *testing.T) {
	slots := []protocol.BackendSlotCapacity{
		// Big-KV slot with an active request whose POTENTIAL growth (4k tokens =
		// 0.4 GB) dwarfs its live used (0). Grant = 10k × 100 kB = 1 GB.
		{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000, MaxTokensPotential: 4_000},
		// Small-KV co-resident grant = 100k × 10 kB = 1 GB.
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
	if pool.totalBytes != 2_000_000_000 {
		t.Fatalf("totalBytes = %d, want 2e9 (sum of byte grants); committed potential must NOT inflate the pool total", pool.totalBytes)
	}

	// The pooled gate must charge against the 2 GB physical pool, not the
	// inflated 2.4 GB: 20k big-KV tokens (2 GB) fit, 20_001 and 24k do not.
	snap := routingSnapshot{
		activeTokenBudgetMax:      10_000,
		kvBytesPerToken:           100_000,
		pendingMaxBytesAllModels:  0,
		pendingMaxTokensAllModels: 0,
		pendingBytesKnown:         true,
		pooledTokenBudget:         pool,
	}
	if pooledBudgetAdmits(snapPtr(snap), 24_000) {
		t.Fatal("admitted 2.4 GB into a 2 GB byte pool — MaxTokensPotential double-counted as physical KV capacity")
	}
	if pooledBudgetAdmits(snapPtr(snap), 20_001) {
		t.Fatal("admitted past the 2 GB byte pool")
	}
	if !pooledBudgetAdmits(snapPtr(snap), 20_000) {
		t.Fatal("rejected 2 GB that fits the 2 GB byte pool (byte total under-counted)")
	}
}

// TestModelCapacitySnapshotByteModePooledClamp is the byte-unit capacity-feed
// regression (Finding 1): on a mixed-KV provider the public snapshot must
// clamp advertised budget in BYTES, matching pooledBudgetAdmits, not in tokens.
// A re-slice shrank gemma's (100 kB/token) grant to 100 tokens while 500 are
// still live, leaving 60 MB of the 110 MB of grants — 6k tokens for gpt-oss
// (10 kB/token). Token accounting reads 10_100 − 500 = 9_600 and gpt-oss's own
// slot reads 10k, so both would over-advertise. Fails without routing the
// snapshot through the byte-aware pooledRemainingTokens.
func TestModelCapacitySnapshotByteModePooledClamp(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	p.BackendCapacity.Slots[0].KVBytesPerToken = 10_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                 gemmaBuild,
		State:                 "running",
		ActiveTokenBudgetMax:  100,
		ActiveTokenBudgetUsed: 500,
		KVBytesPerToken:       100_000,
	})
	p.mu.Unlock()

	caps := make(map[string]ModelCapacity)
	for _, c := range reg.ModelCapacitySnapshot() {
		caps[c.ModelID] = c
	}
	gptoss, ok := caps[gptossBuild]
	if !ok {
		t.Fatalf("missing capacity row for %s", gptossBuild)
	}
	// Byte-accurate: 60 MB remaining ÷ 10 kB/token = 6_000 gpt-oss tokens.
	if gptoss.TokenBudgetRemaining != 6_000 {
		t.Fatalf("gpt-oss token_budget_remaining = %d, want 6_000 (60 MB byte headroom); token-mode over-advertised the pool", gptoss.TokenBudgetRemaining)
	}

	// Snapshot verdict must match the admission gate: an 8k-token (80 MB)
	// gpt-oss request does NOT fit the 60 MB byte headroom, so ReserveProvider
	// rejects.
	if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
		RequestID: "probe", Model: gptossBuild, EstimatedPromptTokens: 100, RequestedMaxTokens: 7_900,
	}); got != nil {
		t.Fatalf("gpt-oss admitted 80 MB into 60 MB byte headroom (snapshot/gate disagree; provider %q)", got.ID)
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
			{Model: "big-kv", ActiveTokenBudgetMax: 10_000, KVBytesPerToken: 100_000},   // 1 GB grant
			{Model: "small-kv", ActiveTokenBudgetMax: 100_000, KVBytesPerToken: 10_000}, // 1 GB grant
		}
		pool := providerPooledTokenBudget(slots)
		if !pool.byteMode {
			t.Fatal("pool byteMode = false, want true")
		}
		if got := resolvedPooledKVBytesPerToken(poolPtr(pool), 0); got != kvCacheBytesPerToken {
			t.Fatalf("resolved cold KV rate = %d, want conservative default %d", got, kvCacheBytesPerToken)
		}
		cold := routingSnapshot{
			kvBytesPerToken:   0, // cold/absent slot
			pendingBytesKnown: true,
			pooledTokenBudget: pool,
		}
		// 50k tokens: token fallback would admit (50k <= 110k token pool), but
		// conservative byte pricing (20 GB) is far beyond the 2 GB pool.
		if pooledBudgetAdmits(snapPtr(cold), 50_000) {
			t.Fatal("cold unknown-KV request admitted via token/resident-rate fallback")
		}
		// Control: 2k tokens at the default rate (0.8 GB) remain below 2 GB.
		if !pooledBudgetAdmits(snapPtr(cold), 2_000) {
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
		if !pooledBudgetAdmits(snapPtr(known), 10_000) {
			t.Fatal("known request at the exact 10k boundary rejected")
		}
		if pooledBudgetAdmits(snapPtr(known), 10_001) {
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

	if pooledBudgetAdmits(snapPtr(snap), 3_000) {
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
	if pooledBudgetAdmits(snapPtr(snap), 20_000) {
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
	if got := addPooledKVByteCharge(0, overflowTokens, resolvedPooledKVBytesPerToken(poolPtr(snap.pooledTokenBudget), 0)); got != math.MaxInt64 {
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
				if admits, want := pooledBudgetAdmits(snapPtr(tc.snap), n), n <= rem; admits != want {
					t.Fatalf("n=%d: pooledBudgetAdmits=%v, but (n<=rem=%d)=%v", n, admits, rem, want)
				}
			}
		})
	}
}

// TestFreeMemoryAdmitsBudgetlessSlotUnchanged: a slot that reports no token
// budget (ActiveTokenBudgetMax == 0) never reaches the budget branch — the
// memory-estimation path is untouched by the pooled fields.
func TestFreeMemoryAdmitsBudgetlessSlotUnchanged(t *testing.T) {
	snap := routingSnapshot{
		modelLoaded:               true,
		totalMemoryGB:             64,
		gpuMemoryActiveGB:         10,
		modelSizeGB:               14,
		pendingMaxTokensAllModels: 1 << 30, // must be ignored on the memory-estimation path
	}
	if !freeMemoryAdmits(snapPtr(snap), 100, 1_900) {
		t.Fatal("budget-less admission changed: loaded model with free memory must admit")
	}
}
