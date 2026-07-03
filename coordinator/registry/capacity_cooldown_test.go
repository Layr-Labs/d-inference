package registry

import (
	"fmt"
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
	expiry, ok := r.capacityCooldowns[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]
	return expiry, ok
}

func capacityCooldownTripsOf(r *Registry, providerID, modelID string) int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.capacityCooldownTrips[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]
}

// expireCapacityCooldown rewinds the pair's cooldown expiry into the past,
// simulating the TTL elapsing (active -> half-open re-probe) without sleeping.
func expireCapacityCooldown(r *Registry, providerID, modelID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.capacityCooldowns[capacityRejectKey{ProviderID: providerID, ModelID: modelID}] = time.Now().Add(-time.Second)
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
		r.capacityCooldowns[key] = past
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
