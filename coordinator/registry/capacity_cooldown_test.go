package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// --- test helpers (poke internal maps / call *Locked helpers, mirroring
// error_cooldown_test.go and provider_breaker_test.go) ---

// expireCapacityCooldown rewinds the pair's cooldown expiry into the past
// (and clears any probe claim), simulating the TTL elapsing (active ->
// half-open, probe unclaimed) without sleeping.
func expireCapacityCooldown(r *Registry, providerID, modelID string) {
	s := r.faults.StatusForSession(providerID, modelID, "")
	if !s.CapacityPresent {
		return
	}
	// Real accepts clear the old cycle; lifecycle rejects recreate the same
	// first-trip half-open entry without adding clamp or rate outcomes.
	r.RecordCapacityAcceptOutcome(providerID, modelID, false)
	cfg := r.faults.Policy().CapacityCooldown
	withFaultFixtureTime(r, time.Now().Add(-cfg.BaseTTL-time.Second), func() {
		for range cfg.Threshold {
			r.RecordCapacityRejectLifecycle(providerID, modelID)
		}
	})
}

// TRUE HALF-OPEN, concurrency: when a cooldown expires, EXACTLY ONE of N
// concurrent reservations passes as the probe — the rest keep seeing the
// cooldown (no thundering herd into a possibly-still-black-holed pair). The
// claim rides ReserveProviderEx's r.mu write lock, so this drives the REAL
// reservation path, not the gate helper in isolation.
func TestCapacityCooldownHalfOpenExactlyOneProbe(t *testing.T) {
	r := newClockedFaultRegistry(t)
	const model = "gemma-4-26b-8bit"
	p := makeSchedulerProvider(t, r, "prov-halfopen", model, 100)

	for i := 0; i < r.faults.Policy().CapacityCooldown.Threshold; i++ {
		r.RecordCapacityReject(p.ID, model)
	}
	expireCapacityCooldown(r, p.ID, model)

	const n = 32
	var wg sync.WaitGroup
	got := make([]*Provider, n)
	start := make(chan struct{})
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			prov, _ := r.ReserveProviderEx(model, &PendingRequest{
				RequestID:             fmt.Sprintf("probe-%d", i),
				Model:                 model,
				EstimatedPromptTokens: 50,
				RequestedMaxTokens:    32,
			})
			got[i] = prov
		}(i)
	}
	close(start)
	wg.Wait()

	probes := 0
	for _, prov := range got {
		if prov != nil {
			probes++
		}
	}
	if probes != 1 {
		t.Fatalf("%d of %d concurrent reservations passed the expired cooldown, want exactly 1 probe", probes, n)
	}
	// The claimed-probe window keeps the gate closed for any late arrival too.
	if prov, _ := r.ReserveProviderEx(model, &PendingRequest{
		RequestID: "late", Model: model, EstimatedPromptTokens: 50, RequestedMaxTokens: 32,
	}); prov != nil {
		t.Fatal("late reservation passed while the probe outcome was still pending")
	}
	// Probe REJECTED: re-arm; everyone (including a next fresh request) is out.
	if !r.RecordCapacityReject(p.ID, model) {
		t.Fatal("failed probe did not re-arm")
	}
	if !r.CapacityCooldownActive(p.ID, model) {
		t.Fatal("cooldown not active after the failed probe")
	}
}

// Regression (PR #510 Codex P2): the preflight's cooldown-only recheck must
// apply the same structural filters as the main candidate path — vision in
// particular. A capacity-cooled TEXT-ONLY pair can never serve a vision
// request; counting it as a capacityRejection surfaced a false "at capacity"
// 429 (retry forever) where the vision/model-unavailable path is the truth.
func TestCapacityCooldownPreflightVisionExcludesTextOnlyCooledPairs(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-8bit"
	p := makeSchedulerProvider(t, r, "text-only", model, 200) // IsVision unset → text build

	for i := 0; i < r.faults.Policy().CapacityCooldown.Threshold; i++ {
		r.RecordCapacityReject(p.ID, model)
	}

	// Text request: the cooled pair IS transient capacity (429 + Retry-After).
	_, capRejText, _, _, _ := r.QuickCapacityCheckWithTTFTForRequest(model, 10, 128, RequestTraits{}, false)
	if capRejText != 1 {
		t.Fatalf("text preflight capacityRejections = %d, want 1 (cooled pair is transient capacity)", capRejText)
	}

	// Vision request: same cooled pair is structurally unservable → not counted.
	cc, capRejVis, _, _, _ := r.QuickCapacityCheckWithTTFTForRequest(model, 10, 128, RequestTraits{}, true)
	if cc != 0 {
		t.Fatalf("vision preflight candidates = %d, want 0", cc)
	}
	if capRejVis != 0 {
		t.Fatalf("vision preflight capacityRejections = %d, want 0 (text-only cooled pair must not read as vision capacity)", capRejVis)
	}
}

// Regression (PR #510 Codex round-2): the cooldown-only preflight recheck must
// apply the SAME structural exclusions as the main path below it. A cooled
// pair that is ALSO thermally critical is excluded outright; a cooled pair
// whose model can never fit the hardware counts as modelTooLarge, never as
// transient capacity (or undersized cooled boxes read as "busy, retry" for a
// model that will never fit).
func TestCapacityCooldownPreflightAppliesThermalAndFitFilters(t *testing.T) {
	const model = "gemma-4-26b-8bit"

	// Thermal-critical cooled pair: excluded from both counts.
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "hot-box", model, 200)
	for i := 0; i < r.faults.Policy().CapacityCooldown.Threshold; i++ {
		r.RecordCapacityReject(p.ID, model)
	}
	p.mu.Lock()
	p.SystemMetrics.ThermalState = "critical"
	p.mu.Unlock()
	cc, capRej, tooLarge := r.QuickCapacityCheck(model, 10, 128, RequestTraits{})
	if cc != 0 || capRej != 0 || tooLarge != 0 {
		t.Fatalf("thermal-critical cooled pair = (cand=%d, rej=%d, tooLarge=%d), want 0/0/0", cc, capRej, tooLarge)
	}

	// Undersized cooled pair (cold model, catalog says it can never fit):
	// counts as modelTooLarge, not capacityRejections.
	r2 := New(testLogger())
	r2.SetModelCatalog([]CatalogEntry{{ID: model, SizeGB: 128}}) // needs far more than 24GB
	small := makeSchedulerProvider(t, r2, "small-box", model, 200)
	small.mu.Lock()
	small.BackendCapacity.TotalMemoryGB = 24
	small.BackendCapacity.Slots[0].State = "idle_shutdown" // cold: fit gate applies
	small.mu.Unlock()
	for i := 0; i < r2.faults.Policy().CapacityCooldown.Threshold; i++ {
		r2.RecordCapacityReject(small.ID, model)
	}
	cc2, capRej2, tooLarge2 := r2.QuickCapacityCheck(model, 10, 128, RequestTraits{})
	if cc2 != 0 || capRej2 != 0 || tooLarge2 != 1 {
		t.Fatalf("undersized cooled pair = (cand=%d, rej=%d, tooLarge=%d), want 0/0/1", cc2, capRej2, tooLarge2)
	}
}
