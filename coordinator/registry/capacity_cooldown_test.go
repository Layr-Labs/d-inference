package registry

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// --- test helpers (poke internal maps / call *Locked helpers, mirroring
// error_cooldown_test.go and provider_breaker_test.go) ---

func capacityCooldownActiveAt(r *Registry, providerID, modelID string, now time.Time) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.capacityCooldownActiveLocked(providerID, modelID, now)
}

func capacityCooldownExpiryOf(r *Registry, providerID, modelID string) (time.Time, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.capacityCooldowns[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]
	if !ok {
		return time.Time{}, false
	}
	return e.expiry, true
}

// claimCapacityProbe claims the pair's half-open probe as ReserveProviderEx
// would at reservation commit (under the r.mu write lock).
func claimCapacityProbe(r *Registry, providerID, modelID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.claimCapacityProbeLocked(providerID, modelID, time.Now())
}

// ageCapacityProbeClaim rewinds the pair's probe claim by d, simulating a
// probe whose outcome never landed (stale claim) without sleeping.
func ageCapacityProbeClaim(r *Registry, providerID, modelID string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if e, ok := r.capacityCooldowns[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]; ok && !e.probeAt.IsZero() {
		e.probeAt = e.probeAt.Add(-d)
	}
}

func capacityCooldownTripsOf(r *Registry, providerID, modelID string) int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.capacityCooldownTrips[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]
}

// expireCapacityCooldown rewinds the pair's cooldown expiry into the past
// (and clears any probe claim), simulating the TTL elapsing (active ->
// half-open, probe unclaimed) without sleeping.
func expireCapacityCooldown(r *Registry, providerID, modelID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if e, ok := r.capacityCooldowns[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]; ok {
		e.expiry = time.Now().Add(-time.Second)
		e.probeAt = time.Time{}
	}
}

// ageCapacityStrikes rewinds every recorded reject strike for the pair by d,
// simulating the passage of time without sleeping.
func ageCapacityStrikes(r *Registry, providerID, modelID string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := capacityRejectKey{ProviderID: providerID, ModelID: modelID}
	strikes := r.capacityRejectStrikes[key]
	aged := make([]time.Time, len(strikes))
	for i, ts := range strikes {
		aged[i] = ts.Add(-d)
	}
	r.capacityRejectStrikes[key] = aged
}

// Regression for the 2026-07 black-hole incident: 7 providers capacity-rejected
// 100% of dispatches ("token_budget_exhausted") from their first request while
// idle-looking heartbeats kept them at the top of the scheduler — ~9k rejects
// in 30 min, zero successes. Threshold-many rejects with ZERO interleaved
// accepts must trip the cooldown, exactly once per transition.
func TestCapacityRejectBlackHoleTrips(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-blackhole", "gemma-4-26b-8bit"

	threshold := r.capacityCooldownCfg.Threshold
	if threshold != defaultCapacityCooldownThreshold {
		t.Fatalf("default threshold = %d, want %d", threshold, defaultCapacityCooldownThreshold)
	}

	for i := 1; i < threshold; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatalf("reject %d/%d tripped early", i, threshold)
		}
		if capacityCooldownActiveAt(r, provider, model, time.Now()) {
			t.Fatalf("cooldown active after only %d rejects", i)
		}
	}
	if tripped := r.RecordCapacityReject(provider, model); !tripped {
		t.Fatalf("reject %d did not trip the cooldown", threshold)
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("cooldown not active after trip")
	}
	// In-flight stragglers while cooling: recorded, but never a second
	// transition and never an extension of the expiry.
	expiry, _ := capacityCooldownExpiryOf(r, provider, model)
	for i := 0; i < 3; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("straggler reject reported a second transition while cooling")
		}
	}
	if after, _ := capacityCooldownExpiryOf(r, provider, model); !after.Equal(expiry) {
		t.Fatalf("straggler rejects extended the cooldown: %v -> %v", expiry, after)
	}
	// The first trip uses the base TTL.
	if got, want := time.Until(expiry), defaultCapacityCooldownTTL; got > want || got < want-5*time.Second {
		t.Fatalf("first-trip TTL ≈ %v, want ≈ %v", got, want)
	}
	// A different model on the SAME provider is unaffected (pair-keyed).
	if capacityCooldownActiveAt(r, provider, "other-model", time.Now()) {
		t.Fatal("cooldown leaked to a different model on the same provider")
	}
}

// The balance side of the incident fix: transient fullness is NORMAL. A busy
// box that keeps SERVING while it sheds (accepts interleaved with capacity
// rejects) must never trip, no matter how many rejects accumulate in total.
func TestCapacityRejectBusyButServingNeverTrips(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-busy", "gemma-4-26b-8bit"
	threshold := r.capacityCooldownCfg.Threshold

	// 25 rounds of (threshold-1 rejects, then one accept): 100 rejects total,
	// but never threshold-many without an accept in between.
	for round := 0; round < 25; round++ {
		for i := 0; i < threshold-1; i++ {
			if tripped := r.RecordCapacityReject(provider, model); tripped {
				t.Fatalf("round %d: busy-but-serving provider tripped after %d rejects", round, i+1)
			}
		}
		r.RecordCapacityAccept(provider, model)
	}
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("busy-but-serving provider ended up in cooldown")
	}
	// The accept also cleared the streak: threshold-1 MORE rejects still don't trip.
	for i := 0; i < threshold-1; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("accept did not reset the reject streak")
		}
	}
}

// An accept mid-cooldown (e.g. the completion of a request dispatched before
// the trip) immediately clears the cooldown AND the backoff state — the pair
// has proven it can serve.
func TestCapacityAcceptClearsActiveCooldownAndBackoff(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-recover", "gemma-4-26b-8bit"
	threshold := r.capacityCooldownCfg.Threshold

	for i := 0; i < threshold; i++ {
		r.RecordCapacityReject(provider, model)
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("setup: cooldown should be active")
	}
	r.RecordCapacityAccept(provider, model)
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("accept did not clear the active cooldown")
	}
	if trips := capacityCooldownTripsOf(r, provider, model); trips != 0 {
		t.Fatalf("accept did not reset the trip count: %d", trips)
	}
	// After the accept the pair is FRESH: it needs the full threshold again
	// (not the half-open single-reject re-arm) and the next trip uses the BASE
	// TTL (backoff reset).
	for i := 1; i < threshold; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatalf("post-accept reject %d re-tripped before the full threshold", i)
		}
	}
	if tripped := r.RecordCapacityReject(provider, model); !tripped {
		t.Fatal("full threshold after accept did not trip")
	}
	expiry, _ := capacityCooldownExpiryOf(r, provider, model)
	if got, want := time.Until(expiry), defaultCapacityCooldownTTL; got > want || got < want-5*time.Second {
		t.Fatalf("post-accept trip TTL ≈ %v, want base ≈ %v (backoff must have reset)", got, want)
	}
}

// Cooldown expiry re-probes the pair (gate reads false), and a still-rejecting
// pair re-arms on its FIRST post-expiry reject with exponentially doubled TTL,
// capped at MaxTTL.
func TestCapacityCooldownExpiryReprobeAndExponentialBackoff(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-repeat", "gemma-4-26b-8bit"
	cfg := r.capacityCooldownCfg

	for i := 0; i < cfg.Threshold; i++ {
		r.RecordCapacityReject(provider, model)
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("setup: first trip should be active")
	}

	wantTTL := cfg.BaseTTL
	for round := 0; round < 5; round++ {
		expireCapacityCooldown(r, provider, model)
		if capacityCooldownActiveAt(r, provider, model, time.Now()) {
			t.Fatalf("round %d: expired cooldown still reads active — re-probe blocked", round)
		}
		// The re-probe was dispatched and REJECTED again: one reject re-arms.
		if tripped := r.RecordCapacityReject(provider, model); !tripped {
			t.Fatalf("round %d: failed re-probe did not re-arm the cooldown", round)
		}
		wantTTL *= 2
		if wantTTL > cfg.MaxTTL {
			wantTTL = cfg.MaxTTL
		}
		expiry, ok := capacityCooldownExpiryOf(r, provider, model)
		if !ok {
			t.Fatalf("round %d: no cooldown expiry after re-arm", round)
		}
		if got := time.Until(expiry); got > wantTTL || got < wantTTL-5*time.Second {
			t.Fatalf("round %d: backoff TTL ≈ %v, want ≈ %v", round, got, wantTTL)
		}
	}
	// 120s -> 240s -> 480s -> 600s (cap) -> 600s: the final rounds must sit at MaxTTL.
	if wantTTL != cfg.MaxTTL {
		t.Fatalf("test walked %v but never reached the %v cap", wantTTL, cfg.MaxTTL)
	}
}

// Strikes older than the window never combine with fresh ones: 4 stale rejects
// plus 1 fresh one is a streak of 1, not 5.
func TestCapacityRejectWindowSlides(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-window", "gemma-4-26b-8bit"
	cfg := r.capacityCooldownCfg

	for i := 0; i < cfg.Threshold-1; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("tripped below threshold")
		}
	}
	// Age everything past the window; the next reject starts a fresh streak.
	ageCapacityStrikes(r, provider, model, cfg.Window+time.Second)
	if tripped := r.RecordCapacityReject(provider, model); tripped {
		t.Fatal("stale strikes outside the window combined with a fresh one to trip")
	}
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("cooldown active after windowed strikes expired")
	}
}

// The EIGENINFERENCE_CAPACITY_COOLDOWN_* env tunables are honored at Registry
// construction: threshold, window, base TTL, and the backoff cap.
func TestCapacityCooldownEnvTunables(t *testing.T) {
	t.Setenv(envCapacityCooldownThreshold, "2")
	t.Setenv(envCapacityCooldownWindowSecs, "30")
	t.Setenv(envCapacityCooldownTTLSecs, "45")
	t.Setenv(envCapacityCooldownMaxTTLSecs, "90")
	r := New(nil)

	want := capacityCooldownConfig{Threshold: 2, Window: 30 * time.Second, BaseTTL: 45 * time.Second, MaxTTL: 90 * time.Second}
	if r.capacityCooldownCfg != want {
		t.Fatalf("config = %+v, want %+v", r.capacityCooldownCfg, want)
	}

	const provider, model = "prov-env", "gemma-4-26b-8bit"
	if tripped := r.RecordCapacityReject(provider, model); tripped {
		t.Fatal("tripped on the first reject with threshold 2")
	}
	if tripped := r.RecordCapacityReject(provider, model); !tripped {
		t.Fatal("did not trip on the second reject with threshold 2")
	}
	expiry, _ := capacityCooldownExpiryOf(r, provider, model)
	if got := time.Until(expiry); got > 45*time.Second || got < 40*time.Second {
		t.Fatalf("first-trip TTL ≈ %v, want ≈ 45s", got)
	}
	// Backoff: 45s -> 90s (cap) -> stays 90s.
	for round, wantTTL := range []time.Duration{90 * time.Second, 90 * time.Second} {
		expireCapacityCooldown(r, provider, model)
		if tripped := r.RecordCapacityReject(provider, model); !tripped {
			t.Fatalf("round %d: failed re-probe did not re-arm", round)
		}
		expiry, _ := capacityCooldownExpiryOf(r, provider, model)
		if got := time.Until(expiry); got > wantTTL || got < wantTTL-5*time.Second {
			t.Fatalf("round %d: TTL ≈ %v, want cap ≈ %v", round, got, wantTTL)
		}
	}
}

// Threshold 0 is the kill switch: nothing is recorded, nothing ever trips.
func TestCapacityCooldownDisabledViaThresholdZero(t *testing.T) {
	t.Setenv(envCapacityCooldownThreshold, "0")
	r := New(nil)
	const provider, model = "prov-disabled", "gemma-4-26b-8bit"
	for i := 0; i < 50; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("disabled cooldown tripped")
		}
	}
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("disabled cooldown reads active")
	}
}

// Nonsensical env values (unparseable / non-positive durations / cap below
// base) fall back to safe defaults instead of a zero-window or zero-TTL config.
func TestCapacityCooldownConfigClamps(t *testing.T) {
	t.Setenv(envCapacityCooldownThreshold, "banana")
	t.Setenv(envCapacityCooldownWindowSecs, "-5")
	t.Setenv(envCapacityCooldownTTLSecs, "0")
	t.Setenv(envCapacityCooldownMaxTTLSecs, "1") // below base -> raised to base
	cfg := loadCapacityCooldownConfig()
	if cfg.Threshold != defaultCapacityCooldownThreshold {
		t.Fatalf("Threshold = %d, want default %d", cfg.Threshold, defaultCapacityCooldownThreshold)
	}
	if cfg.Window != defaultCapacityCooldownWindow {
		t.Fatalf("Window = %v, want default %v", cfg.Window, defaultCapacityCooldownWindow)
	}
	if cfg.BaseTTL != defaultCapacityCooldownTTL {
		t.Fatalf("BaseTTL = %v, want default %v", cfg.BaseTTL, defaultCapacityCooldownTTL)
	}
	if cfg.MaxTTL != cfg.BaseTTL {
		t.Fatalf("MaxTTL = %v, want raised to BaseTTL %v", cfg.MaxTTL, cfg.BaseTTL)
	}
}

// TRUE HALF-OPEN, claim lifecycle: after expiry the gate is open only while no
// probe claim is fresh. A claim (as ReserveProviderEx makes at reservation
// commit) closes it for everyone else; a stale claim (probe outcome never
// landed) reopens it; a rejected probe re-arms with doubled TTL; an accepted
// probe clears the pair entirely.
func TestCapacityCooldownProbeClaimLifecycle(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-probe", "gemma-4-26b-8bit"
	cfg := r.capacityCooldownCfg

	for i := 0; i < cfg.Threshold; i++ {
		r.RecordCapacityReject(provider, model)
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("setup: cooldown should be active")
	}

	// Expiry, unclaimed: gate open (a probe may be reserved).
	expireCapacityCooldown(r, provider, model)
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("expired unclaimed cooldown still reads active")
	}
	// Claim the probe: gate closes for everyone else while the outcome pends.
	claimCapacityProbe(r, provider, model)
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("gate open to the herd while the probe outcome is pending")
	}
	// Probe outcome never lands: the claim goes stale after
	// capacityProbeOutcomeWindow and the gate reopens for a fresh probe.
	ageCapacityProbeClaim(r, provider, model, capacityProbeOutcomeWindow+time.Second)
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("stale probe claim wedged the pair closed")
	}
	// Fresh claim, probe REJECTED: immediate re-arm with doubled TTL, and the
	// new entry's probe slot is unclaimed again.
	claimCapacityProbe(r, provider, model)
	if !r.RecordCapacityReject(provider, model) {
		t.Fatal("rejected probe did not re-arm the cooldown")
	}
	expiry, _ := capacityCooldownExpiryOf(r, provider, model)
	if got, want := time.Until(expiry), 2*cfg.BaseTTL; got > want || got < want-5*time.Second {
		t.Fatalf("re-arm TTL ≈ %v, want doubled ≈ %v", got, want)
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("re-armed cooldown not active")
	}
	// Next cycle: expire, claim, probe ACCEPTED: everything clears.
	expireCapacityCooldown(r, provider, model)
	claimCapacityProbe(r, provider, model)
	r.RecordCapacityAccept(provider, model)
	if capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("accepted probe did not clear the cooldown")
	}
	if trips := capacityCooldownTripsOf(r, provider, model); trips != 0 {
		t.Fatalf("accepted probe did not reset the trip count: %d", trips)
	}
}

// TRUE HALF-OPEN, concurrency: when a cooldown expires, EXACTLY ONE of N
// concurrent reservations passes as the probe — the rest keep seeing the
// cooldown (no thundering herd into a possibly-still-black-holed pair). The
// claim rides ReserveProviderEx's r.mu write lock, so this drives the REAL
// reservation path, not the gate helper in isolation.
func TestCapacityCooldownHalfOpenExactlyOneProbe(t *testing.T) {
	r := New(testLogger())
	const model = "gemma-4-26b-8bit"
	p := makeSchedulerProvider(t, r, "prov-halfopen", model, 100)

	for i := 0; i < r.capacityCooldownCfg.Threshold; i++ {
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

// Map-bound sweep: expired cooldowns and idle strike lists are dropped once the
// maps grow past the bound, so per-session UUID keys cannot leak forever.
func TestCapacityCooldownMapsBounded(t *testing.T) {
	r := New(nil)
	const model = "gemma-4-26b-8bit"
	cfg := r.capacityCooldownCfg

	// Seed >1024 expired cooldowns and stale strike lists directly.
	r.mu.Lock()
	past := time.Now().Add(-time.Hour)
	for i := 0; i < 1100; i++ {
		key := capacityRejectKey{ProviderID: fmt.Sprintf("dead-%d", i), ModelID: model}
		r.capacityCooldowns[key] = &capacityCooldownEntry{expiry: past}
		r.capacityCooldownTrips[key] = 1
		r.capacityRejectStrikes[key] = []time.Time{past.Add(-cfg.Window)}
	}
	r.mu.Unlock()

	r.RecordCapacityReject("prov-live", model)

	r.mu.RLock()
	cooldowns, strikes := len(r.capacityCooldowns), len(r.capacityRejectStrikes)
	r.mu.RUnlock()
	if cooldowns > 8 {
		t.Fatalf("expired cooldowns not swept: %d entries remain", cooldowns)
	}
	if strikes > 8 {
		t.Fatalf("stale strike lists not swept: %d entries remain", strikes)
	}
}

// Regression (PR #510 Codex P2): the >1024 bound sweep must NOT delete a
// half-open entry whose probe claim is still fresh. In that state expiry is
// deliberately in the past and probeAt is the only thing holding the gate
// closed while the single probe's outcome pends — sweeping it (triggered by a
// reject on ANY other pair) reopened the gate to a thundering herd mid-probe
// and dropped the pair's exponential-backoff state.
func TestCapacityCooldownSweepPreservesFreshProbeClaims(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-probed", "gemma-4-26b-8bit"
	cfg := r.capacityCooldownCfg

	// Trip the pair, expire the TTL, claim the half-open probe.
	for i := 0; i < cfg.Threshold; i++ {
		r.RecordCapacityReject(provider, model)
	}
	expireCapacityCooldown(r, provider, model)
	claimCapacityProbe(r, provider, model)
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("setup: pending probe should hold the gate closed")
	}

	// Grow the map past the sweep bound with long-expired junk entries.
	r.mu.Lock()
	for i := 0; i < 1100; i++ {
		key := capacityRejectKey{ProviderID: fmt.Sprintf("junk-%d", i), ModelID: model}
		r.capacityCooldowns[key] = &capacityCooldownEntry{expiry: time.Now().Add(-time.Hour)}
		r.capacityCooldownTrips[key] = 1
	}
	r.mu.Unlock()

	// A reject on an unrelated pair triggers the opportunistic sweep.
	r.RecordCapacityReject("prov-other", model)

	key := capacityRejectKey{ProviderID: provider, ModelID: model}
	r.mu.RLock()
	_, probedAlive := r.capacityCooldowns[key]
	trips := r.capacityCooldownTrips[key]
	size := len(r.capacityCooldowns)
	r.mu.RUnlock()
	if !probedAlive {
		t.Fatal("sweep deleted the half-open entry with a fresh probe claim")
	}
	if trips == 0 {
		t.Fatal("sweep dropped the pair's backoff state mid-probe")
	}
	if size > 8 {
		t.Fatalf("junk entries not bounded by the sweep: %d remain", size)
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("gate reopened to the herd mid-probe after the sweep")
	}

	// A STALE claim (outcome never landed) must still be sweepable — the
	// liveness bound, not the claim itself, decides retention.
	ageCapacityProbeClaim(r, provider, model, capacityProbeOutcomeWindow+time.Second)
	r.mu.Lock()
	for i := 0; i < 1100; i++ {
		key := capacityRejectKey{ProviderID: fmt.Sprintf("junk2-%d", i), ModelID: model}
		r.capacityCooldowns[key] = &capacityCooldownEntry{expiry: time.Now().Add(-time.Hour)}
	}
	r.mu.Unlock()
	r.RecordCapacityReject("prov-other-2", model)
	r.mu.RLock()
	_, staleAlive := r.capacityCooldowns[key]
	r.mu.RUnlock()
	if staleAlive {
		t.Fatal("sweep retained an entry whose probe claim went stale")
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

	for i := 0; i < r.capacityCooldownCfg.Threshold; i++ {
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
