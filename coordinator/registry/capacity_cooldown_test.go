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
	return r.capacityCooled(providerID, modelID, now)
}

func capacityCooldownExpiryOf(r *Registry, providerID, modelID string) (expiry time.Time, ok bool) {
	readGateForSession(r, providerID, func(g *gateState) {
		if g == nil {
			return
		}
		if e, has := g.capacityCooldowns[modelID]; has {
			expiry, ok = e.expiry, true
		}
	})
	return expiry, ok
}

// claimCapacityProbe claims the pair's half-open probe as the reservation
// commit would (check-and-claim under gate.mu); returns whether the claim
// went through (false = the gate was closed to this request).
func claimCapacityProbe(r *Registry, providerID, modelID string) bool {
	if p := r.sessionProvider(providerID); p != nil {
		return r.tryClaimCapacityProbe(p, modelID, time.Now())
	}
	return r.claimCapacityProbeRef(r.gateForSession(providerID), modelID, time.Now())
}

// ageCapacityProbeClaim rewinds the pair's probe claim by d, simulating a
// probe whose outcome never landed (stale claim) without sleeping.
func ageCapacityProbeClaim(r *Registry, providerID, modelID string, d time.Duration) {
	withGateForSession(r, providerID, func(g *gateState) {
		if e, ok := g.capacityCooldowns[modelID]; ok && !e.probeAt.IsZero() {
			e.probeAt = e.probeAt.Add(-d)
		}
	})
}

func capacityCooldownTripsOf(r *Registry, providerID, modelID string) (trips int) {
	readGateForSession(r, providerID, func(g *gateState) {
		if g != nil {
			trips = g.capacityCooldownTrips[modelID]
		}
	})
	return trips
}

// expireCapacityCooldown rewinds the pair's cooldown expiry into the past
// (and clears any probe claim), simulating the TTL elapsing (active ->
// half-open, probe unclaimed) without sleeping.
func expireCapacityCooldown(r *Registry, providerID, modelID string) {
	withGateForSession(r, providerID, func(g *gateState) {
		if e, ok := g.capacityCooldowns[modelID]; ok {
			e.expiry = time.Now().Add(-time.Second)
			e.probeAt = time.Time{}
		}
	})
}

// ageCapacityStrikes rewinds every recorded reject strike for the pair by d,
// simulating the passage of time without sleeping.
func ageCapacityStrikes(r *Registry, providerID, modelID string, d time.Duration) {
	withGateForSession(r, providerID, func(g *gateState) {
		strikes := g.capacityRejectStrikes[modelID]
		aged := make([]time.Time, len(strikes))
		for i, ts := range strikes {
			aged[i] = ts.Add(-d)
		}
		g.capacityRejectStrikes[modelID] = aged
	})
}

// capacityCooldownEntryOf returns the pair's cooldown entry pointer (nil when
// none), for tests that inspect the probe claim directly.
func capacityCooldownEntryOf(r *Registry, providerID, modelID string) (entry *capacityCooldownEntry) {
	readGateForSession(r, providerID, func(g *gateState) {
		if g != nil {
			entry = g.capacityCooldowns[modelID]
		}
	})
	return entry
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

// Gate sweep: identities whose only capacity state is an expired cooldown and
// aged-out strikes are idle, so once no live session references them and the
// idle grace has passed the periodic sweep drops their gates — per-session
// UUID keys cannot leak forever.
func TestCapacityCooldownMapsBounded(t *testing.T) {
	r := New(nil)
	const model = "gemma-4-26b-8bit"
	cfg := r.capacityCooldownCfg

	// Seed >1024 dead identities with expired cooldowns and stale strikes.
	past := time.Now().Add(-time.Hour)
	for i := 0; i < 1100; i++ {
		withGateForKey(r, fmt.Sprintf("dead-%d", i), func(g *gateState) {
			g.capacityCooldowns[model] = &capacityCooldownEntry{expiry: past}
			g.capacityCooldownTrips[model] = 1
			g.capacityRejectStrikes[model] = []time.Time{past.Add(-cfg.Window)}
			g.touched = past
		})
	}
	if n := r.gateCount(); n < 1100 {
		t.Fatalf("setup produced too few gates: %d", n)
	}

	r.sweepGates(time.Now())

	if n := r.gateCount(); n > 8 {
		t.Fatalf("idle identities not swept: %d gates remain", n)
	}
}

// Regression (PR #510 Codex P2): the sweep must NOT delete a half-open entry
// whose probe claim is still fresh. In that state expiry is deliberately in the
// past and probeAt is the only thing holding the gate closed while the single
// probe's outcome pends — sweeping it reopened the gate to a thundering herd
// mid-probe and dropped the pair's exponential-backoff state. With per-identity
// gates the same rule holds twice over: a gate with a live session is never
// dropped, and a fresh claim keeps even a disconnected identity's gate non-idle.
func TestCapacityCooldownSweepPreservesFreshProbeClaims(t *testing.T) {
	r := New(nil)
	const provider, model = "prov-probed", "gemma-4-26b-8bit"
	cfg := r.capacityCooldownCfg

	// Trip the pair, expire the TTL, claim the half-open probe.
	for i := 0; i < cfg.Threshold; i++ {
		r.RecordCapacityReject(provider, model)
	}
	expireCapacityCooldown(r, provider, model)
	if !claimCapacityProbe(r, provider, model) {
		t.Fatal("setup: the first post-expiry claim must succeed")
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("setup: pending probe should hold the gate closed")
	}
	// Age every other tracker the rejects armed (strikes, the gray-box clamp
	// and rate window) out of their windows and backdate the identity's last
	// activity, so the fresh probe claim is the ONLY thing keeping the gate.
	ageCapacityStrikes(r, provider, model, cfg.Window+time.Second)
	ageBudgetClamp(r, provider, model, r.budgetClampCfg.TTL+time.Second)
	ageCapacityRateRejects(r, provider, model, capacityRateWindow+time.Second)
	withGateForSession(r, provider, func(g *gateState) { g.touched = time.Now().Add(-time.Hour) })

	// Grow the index past the high-water mark with long-idle junk identities.
	for i := 0; i < 1100; i++ {
		withGateForKey(r, fmt.Sprintf("junk-%d", i), func(g *gateState) {
			g.capacityCooldowns[model] = &capacityCooldownEntry{expiry: time.Now().Add(-time.Hour)}
			g.capacityCooldownTrips[model] = 1
			g.touched = time.Now().Add(-time.Hour)
		})
	}

	r.sweepGates(time.Now())

	entry := capacityCooldownEntryOf(r, provider, model)
	trips := capacityCooldownTripsOf(r, provider, model)
	if entry == nil {
		t.Fatal("sweep deleted the half-open entry with a fresh probe claim")
	}
	if trips == 0 {
		t.Fatal("sweep dropped the pair's backoff state mid-probe")
	}
	if n := r.gateCount(); n > 8 {
		t.Fatalf("junk identities not bounded by the sweep: %d remain", n)
	}
	if !capacityCooldownActiveAt(r, provider, model, time.Now()) {
		t.Fatal("gate reopened to the herd mid-probe after the sweep")
	}

	// A STALE claim (outcome never landed) must still be sweepable — the
	// liveness bound, not the claim itself, decides retention.
	ageCapacityProbeClaim(r, provider, model, capacityProbeOutcomeWindow+time.Second)
	withGateForSession(r, provider, func(g *gateState) { g.touched = time.Now().Add(-time.Hour) })
	r.sweepGates(time.Now())
	if rawGateForKey(r, provider) != nil {
		t.Fatal("sweep retained an identity whose probe claim went stale")
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
	for i := 0; i < r.capacityCooldownCfg.Threshold; i++ {
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
	for i := 0; i < r2.capacityCooldownCfg.Threshold; i++ {
		r2.RecordCapacityReject(small.ID, model)
	}
	cc2, capRej2, tooLarge2 := r2.QuickCapacityCheck(model, 10, 128, RequestTraits{})
	if cc2 != 0 || capRej2 != 0 || tooLarge2 != 1 {
		t.Fatalf("undersized cooled pair = (cand=%d, rej=%d, tooLarge=%d), want 0/0/1", cc2, capRej2, tooLarge2)
	}
}
