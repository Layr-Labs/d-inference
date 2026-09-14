package registry

import (
	"fmt"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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

	if got := pool.KVRateFor(gemmaBuild); got != knownZeroRate {
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
	if !pendingSnap.PendingBytesKnown {
		t.Fatal("zero-budget resident disabled byte accounting")
	}
	if got := pendingSnap.PendingMaxBytesAllModels; got != knownZeroRate {
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
	// still exposes the full shared pool. The known-zero model must reject and
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

	// Leave 500 kB of the shared 1 GB pool. That fits one token only under the
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

// TestConcurrentReservationScansCommitPooledBudgetAtomically proves the
// production primary path can scan different models concurrently without
// double-spending one provider's cross-model token pool. Both scans rendezvous
// after seeing the same empty heartbeat snapshot; the short serialized commit
// must admit exactly one 2k request into the shared 3k pool.
func TestConcurrentReservationScansCommitPooledBudgetAtomically(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "shared-box", gptossBuild, 93)
	addAdvertisedModel(p, gemmaBuild)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 3_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 3_000,
	})
	p.mu.Unlock()

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
	for i, model := range []string{gptossBuild, gemmaBuild} {
		go func() {
			<-start
			requestID := fmt.Sprintf("concurrent-%d", i)
			provider, _, _ := reg.ReserveProviderWithPlan(model, &PendingRequest{
				RequestID:             requestID,
				Model:                 model,
				EstimatedPromptTokens: 100,
				RequestedMaxTokens:    1_900,
			})
			results <- result{requestID: requestID, provider: provider}
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

// TestPooledAdmissionV075PrivateGrantsPreserveCrossModelCapacity pins the
// release boundary between the legacy scheduler's shared-headroom reports and
// v0.7.5's one-engine re-sliced grants. In v0.7.5 each slot max is a private
// engine ceiling, so two 10k slots expose 20k aggregate capacity while each
// model still has its own 10k limit. Older providers report the same shared
// headroom through every slot, so their two 10k views still represent one 10k
// box-wide pool.
func TestPooledAdmissionV075PrivateGrantsPreserveCrossModelCapacity(t *testing.T) {
	configure := func(version, id string) (*Registry, *Provider) {
		reg := New(testLogger())
		p := makeSchedulerProvider(t, reg, id, gptossBuild, 93)
		addAdvertisedModel(p, gemmaBuild)
		p.mu.Lock()
		p.Version = version
		p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
		p.BackendCapacity.Slots[0].KVBytesPerToken = 100_000
		p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
			Model:                gemmaBuild,
			State:                "running",
			ActiveTokenBudgetMax: 10_000,
			KVBytesPerToken:      100_000,
		})
		p.mu.Unlock()
		return reg, p
	}
	reserve := func(reg *Registry, model, id string, tokens int) *Provider {
		return reg.ReserveProvider(model, &PendingRequest{
			RequestID:             id,
			Model:                 model,
			EstimatedPromptTokens: 100,
			RequestedMaxTokens:    tokens - 100,
		})
	}

	v075, _ := configure("0.7.5", "private-box")
	if got := reserve(v075, gptossBuild, "private-a", 8_000); got == nil {
		t.Fatal("v0.7.5 model A rejected despite fitting its private 10k grant")
	}
	if got := reserve(v075, gemmaBuild, "private-b", 8_000); got == nil {
		t.Fatal("v0.7.5 model B rejected: private 10k grants were collapsed into one shared pool")
	}
	if got := reserve(v075, gemmaBuild, "private-b-overflow", 3_000); got != nil {
		t.Fatalf("v0.7.5 model B exceeded its private 10k grant on provider %q", got.ID)
	}

	legacy, _ := configure("0.7.4", "shared-box-control")
	if got := reserve(legacy, gptossBuild, "shared-a", 8_000); got == nil {
		t.Fatal("v0.7.4 model A rejected despite fitting the shared 10k pool")
	}
	if got := reserve(legacy, gemmaBuild, "shared-b", 8_000); got != nil {
		t.Fatalf("v0.7.4 model B double-spent the shared 10k pool on provider %q", got.ID)
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
	snap.KVBytesPerToken = residentRate

	wantPendingBytes := int64(2_100) * kvCacheBytesPerToken
	if !snap.PendingBytesKnown {
		t.Error("cold pending request disabled provider byte accounting")
	}
	if snap.PendingMaxBytesAllModels != wantPendingBytes {
		t.Errorf("cold pending bytes = %d, want %d at conservative default rate", snap.PendingMaxBytesAllModels, wantPendingBytes)
	}
	if pooledBudgetAdmits(snapPtr(snap), 20_000) {
		t.Error("subsequent resident request admitted via token fallback after cold pending request consumed byte headroom")
	}
	wantRemaining := (snap.PooledTokenBudget.TotalBytes() - wantPendingBytes) / residentRate
	if got := pooledRemainingTokens(
		snap.PooledTokenBudget,
		snap.PendingMaxTokensAllModels,
		snap.PendingMaxBytesAllModels,
		snap.PendingBytesKnown,
		snap.KVBytesPerToken,
	); got != wantRemaining {
		t.Errorf("resident pooled remaining = %d, want %d after default-priced cold pending request", got, wantRemaining)
	}

	overflowTokens := int64(math.MaxInt64/kvCacheBytesPerToken + 1)
	if got := addPooledKVByteCharge(0, overflowTokens, resolvedPooledKVBytesPerToken(poolPtr(snap.PooledTokenBudget), 0)); got != math.MaxInt64 {
		t.Errorf("overflowing cold pending charge = %d, want saturated MaxInt64", got)
	}
}
