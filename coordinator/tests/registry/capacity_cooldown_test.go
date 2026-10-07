package registry_test

import (
	"fmt"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Expired, unreferenced identity state must not grow the directory forever.
func TestCapacityCooldownMapsBounded(t *testing.T) {
	now := time.Now()
	clock := now
	options := identitygate.DefaultOptions()
	options.Now = func() time.Time { return clock }
	r := identitygate.New(nil, &options)
	const model = "gemma-4-26b-8bit"
	cfg := options.CapacityCooldown
	past := now.Add(-time.Hour)
	for i := 0; i < 1100; i++ {
		provider := fmt.Sprintf("dead-%d", i)
		clock = past.Add(-cfg.BaseTTL)
		for j := 0; j < cfg.Threshold; j++ {
			r.RecordCapacityRejectProjected(provider, model, false, false, false)
		}
		clock = past.Add(-cfg.Window)
		r.RecordCapacityRejectProjected(provider, model, false, false, false)
		clock = past
		r.RecordProviderOutcome(provider, false, 429, "")
		assessment := r.ViewIdentity(provider).CapacityAssessment(model)
		if !assessment.Present || assessment.Decision.RetryAfter != past || assessment.Decision.Trips != 1 ||
			!assessment.Decision.ProbeAt.IsZero() || len(assessment.Strikes) != 1 || assessment.Strikes[0] != past.Add(-cfg.Window) {
			t.Fatalf("dead identity %d did not retain the original expired evidence: %+v", i, assessment)
		}
	}
	n := 0
	for i := 0; i < 1100; i++ {
		if r.ViewIdentity(fmt.Sprintf("dead-%d", i)).Present() {
			n++
		}
	}
	if n < 1100 {
		t.Fatalf("setup produced too few gates: %d", n)
	}
	if n := r.Sweep(now); n > 8 {
		t.Fatalf("idle identities not swept: %d gates remain", n)
	}
}

// The probe claim alone must retain an otherwise idle, disconnected identity.
func TestCapacityCooldownSweepPreservesFreshProbeClaims(t *testing.T) {
	now := time.Now()
	clock := now
	options := identitygate.DefaultOptions()
	options.Now = func() time.Time { return clock }
	r := identitygate.New(nil, &options)
	const provider, model = "prov-probed", "gemma-4-26b-8bit"
	cfg := options.CapacityCooldown

	// The constructor clock deliberately moves backward to establish the
	// original independently aged histories through their actual recorders.
	clock = now.Add(-cfg.BaseTTL - time.Second)
	for i := 0; i < cfg.Threshold; i++ {
		r.RecordCapacityRejectProjected(provider, model, false, false, false)
	}
	clock = now.Add(-identitygate.CapacityRateWindow - time.Second)
	for i := 0; i < cfg.Threshold; i++ {
		r.RecordCapacityRejectProjected(provider, model, true, false, false)
	}
	clock = now.Add(-options.BudgetClamp.TTL - time.Second)
	r.RecordCapacityRejectProjected(provider, model, false, true, false)
	clock = now.Add(-cfg.Window - time.Second)
	for i := 0; i < cfg.Threshold; i++ {
		r.RecordCapacityRejectProjected(provider, model, false, false, false)
	}
	clock = now
	if !r.ClaimCapacityProbe(r.ResolveSession(provider, false), model, now) {
		t.Fatal("setup: the first post-expiry claim must succeed")
	}
	if !r.ViewIdentity(provider).CapacityCooled(model, now) {
		t.Fatal("setup: pending probe should hold the gate closed")
	}
	clock = now.Add(-time.Hour)
	r.RecordProviderOutcome(provider, false, 429, "")

	// Create the original 1100 junk identities, then prune their expired
	// strikes while their two-minute activity age is still inside idle grace.
	past := now.Add(-time.Hour)
	clock = past.Add(-cfg.BaseTTL)
	for i := 0; i < 1100; i++ {
		identity := fmt.Sprintf("junk-%d", i)
		for j := 0; j < cfg.Threshold; j++ {
			r.RecordCapacityRejectProjected(identity, model, false, false, false)
		}
	}
	r.Maintain(past)
	clock = past
	for i := 0; i < 1100; i++ {
		identity := fmt.Sprintf("junk-%d", i)
		r.RecordProviderOutcome(identity, false, 429, "")
		assessment := r.ViewIdentity(identity).CapacityAssessment(model)
		if !assessment.Present || assessment.Decision.RetryAfter != past || assessment.Decision.Trips != 1 ||
			!assessment.Decision.ProbeAt.IsZero() || len(assessment.Strikes) != 0 {
			t.Fatalf("junk identity %d did not retain the original expired evidence: %+v", i, assessment)
		}
	}

	view := r.ViewIdentity(provider)
	before := view.CapacityAssessment(model)
	if !before.Present || before.Decision.RetryAfter != now.Add(-time.Second) || before.Decision.Trips != 1 ||
		before.Decision.ProbeAt != now || len(before.Strikes) != cfg.Threshold {
		t.Fatalf("probe identity did not retain the original cooldown evidence: %+v", before)
	}
	for _, stamp := range before.Strikes {
		if stamp != now.Add(-cfg.Window-time.Second) {
			t.Fatalf("capacity strike timestamp = %v, want %v", stamp, now.Add(-cfg.Window-time.Second))
		}
	}
	rejects, accepts := view.RateHistory(model)
	if len(rejects) != cfg.Threshold || len(accepts) != 0 {
		t.Fatalf("rate histories = %v/%v, want threshold rejects and no accepts", rejects, accepts)
	}
	for _, stamp := range rejects {
		if stamp != now.Add(-identitygate.CapacityRateWindow-time.Second) {
			t.Fatalf("rate reject timestamp = %v, want %v", stamp, now.Add(-identitygate.CapacityRateWindow-time.Second))
		}
	}
	clamp := view.BudgetClampAssessment(model)
	if !clamp.Present || clamp.ClampedAt != now.Add(-options.BudgetClamp.TTL-time.Second) || clamp.AcceptedSince || clamp.BudgetReported {
		t.Fatalf("probe identity did not retain the original clamp evidence: %+v", clamp)
	}

	clock = now
	report := r.Maintain(now)
	view = r.ViewIdentity(provider)
	entry := view.CapacityAssessment(model)
	trips := entry.Decision.Trips
	if !entry.Present {
		t.Fatal("sweep deleted the half-open entry with a fresh probe claim")
	}
	if trips == 0 {
		t.Fatal("sweep dropped the pair's backoff state mid-probe")
	}
	if n := report.Retained; n > 8 {
		t.Fatalf("junk identities not bounded by the sweep: %d remain", n)
	}
	if !view.CapacityCooled(model, now) {
		t.Fatal("gate reopened to the herd mid-probe after the sweep")
	}
	rejects, accepts = view.RateHistory(model)
	if len(entry.Strikes) != 0 || len(rejects) != 0 || len(accepts) != 0 || view.BudgetClampAssessment(model).Present {
		t.Fatal("fresh probe was not the sole remaining capacity evidence after the sweep")
	}

	// With every other tracker already gone, advance only the stale-probe
	// liveness interval; no unrelated expiry can make this assertion pass.
	clock = now.Add(30*time.Second + time.Second)
	r.Maintain(clock)
	if r.ViewIdentity(provider).Present() {
		t.Fatal("sweep retained an identity whose probe claim went stale")
	}
}

// Transient fullness is normal: interleaved accepts must prevent a trip even
// when the total number of rejects exceeds the threshold many times over.
func TestCapacityRejectBusyButServingNeverTrips(t *testing.T) {
	r := production.New(nil)
	const provider, model = "prov-busy", "gemma-4-26b-8bit"
	threshold := identitygate.LoadCapacityCooldownConfig().Threshold

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
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("busy-but-serving provider ended up in cooldown")
	}
	// The accept also cleared the streak: threshold-1 MORE rejects still don't trip.
	for i := 0; i < threshold-1; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("accept did not reset the reject streak")
		}
	}
}

// Strikes outside the window must not combine with a fresh reject.
func TestCapacityRejectWindowSlides(t *testing.T) {
	options := identitygate.DefaultOptions()
	now := time.Now()
	options.Now = func() time.Time { return now }
	r := identitygate.New(nil, &options)
	const provider, model = "prov-window", "gemma-4-26b-8bit"
	cfg := options.CapacityCooldown

	for i := 0; i < cfg.Threshold-1; i++ {
		if tripped := r.RecordCapacityRejectProjected(provider, model, true, true, false); tripped {
			t.Fatal("tripped below threshold")
		}
	}
	// Advance the actual recorder clock by the original strike-aging interval.
	now = now.Add(cfg.Window + time.Second)
	if tripped := r.RecordCapacityRejectProjected(provider, model, true, true, false); tripped {
		t.Fatal("stale strikes outside the window combined with a fresh one to trip")
	}
	if r.ViewForSession(nil, provider).CapacityCooled(model, now) {
		t.Fatal("cooldown active after windowed strikes expired")
	}
}

// Preserve the real concurrent reservation path: after expiry exactly one
// reservation claims the probe, and late arrivals stay blocked.
func TestCapacityCooldownHalfOpenExactlyOneProbe(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := production.New(testLogger())
		const model = "gemma-4-26b-8bit"
		p := makeSchedulerProvider(t, r, "prov-halfopen", model, 100)
		cfg := identitygate.LoadCapacityCooldownConfig()

		for i := 0; i < cfg.Threshold; i++ {
			r.RecordCapacityReject(p.ID, model)
		}
		time.Sleep(cfg.BaseTTL + time.Second)

		const n = 32
		var wg sync.WaitGroup
		got := make([]*production.Provider, n)
		start := make(chan struct{})
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				<-start
				prov, _ := r.ReserveProviderEx(model, &production.PendingRequest{
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
		if prov, _ := r.ReserveProviderEx(model, &production.PendingRequest{
			RequestID: "late", Model: model, EstimatedPromptTokens: 50, RequestedMaxTokens: 32,
		}); prov != nil {
			t.Fatal("late reservation passed while the probe outcome was still pending")
		}
		if !r.RecordCapacityReject(p.ID, model) {
			t.Fatal("failed probe did not re-arm")
		}
		if !r.CapacityCooldownActive(p.ID, model) {
			t.Fatal("cooldown not active after the failed probe")
		}
	})
}

// Threshold 0 is the kill switch: nothing is recorded, nothing ever trips.
func TestCapacityCooldownDisabledViaThresholdZero(t *testing.T) {
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD", "0")
	r := production.New(nil)
	const provider, model = "prov-disabled", "gemma-4-26b-8bit"
	for i := 0; i < 50; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("disabled cooldown tripped")
		}
	}
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("disabled cooldown reads active")
	}
}

// Invalid durations fall back to the defaults, and the cap cannot be below base.
func TestCapacityCooldownConfigClamps(t *testing.T) {
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD", "banana")
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_WINDOW_SECONDS", "-5")
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_TTL_SECONDS", "0")
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_MAX_TTL_SECONDS", "1")
	cfg := identitygate.LoadCapacityCooldownConfig()
	if cfg.Threshold != 5 {
		t.Fatalf("Threshold = %d, want default %d", cfg.Threshold, 5)
	}
	if cfg.Window != 60*time.Second {
		t.Fatalf("Window = %v, want default %v", cfg.Window, 60*time.Second)
	}
	if cfg.BaseTTL != 120*time.Second {
		t.Fatalf("BaseTTL = %v, want default %v", cfg.BaseTTL, 120*time.Second)
	}
	if cfg.MaxTTL != cfg.BaseTTL {
		t.Fatalf("MaxTTL = %v, want raised to BaseTTL %v", cfg.MaxTTL, cfg.BaseTTL)
	}
}

// A cooled text-only pair is structurally unavailable to a vision request,
// rather than transient capacity that the caller should retry.
func TestCapacityCooldownPreflightVisionExcludesTextOnlyCooledPairs(t *testing.T) {
	r := production.New(testLogger())
	const model = "gemma-4-26b-8bit"
	p := makeSchedulerProvider(t, r, "text-only", model, 200)

	for i := 0; i < identitygate.LoadCapacityCooldownConfig().Threshold; i++ {
		r.RecordCapacityReject(p.ID, model)
	}

	_, capRejText, _, _, _ := r.QuickCapacityCheckWithTTFTForRequest(model, 10, 128, production.RequestTraits{}, false)
	if capRejText != 1 {
		t.Fatalf("text preflight capacityRejections = %d, want 1 (cooled pair is transient capacity)", capRejText)
	}

	cc, capRejVis, _, _, _ := r.QuickCapacityCheckWithTTFTForRequest(model, 10, 128, production.RequestTraits{}, true)
	if cc != 0 {
		t.Fatalf("vision preflight candidates = %d, want 0", cc)
	}
	if capRejVis != 0 {
		t.Fatalf("vision preflight capacityRejections = %d, want 0 (text-only cooled pair must not read as vision capacity)", capRejVis)
	}
}

// Cooldown-only preflight rechecks retain the main path's structural filters.
func TestCapacityCooldownPreflightAppliesThermalAndFitFilters(t *testing.T) {
	const model = "gemma-4-26b-8bit"

	r := production.New(testLogger())
	p := makeSchedulerProvider(t, r, "hot-box", model, 200)
	for i := 0; i < identitygate.LoadCapacityCooldownConfig().Threshold; i++ {
		r.RecordCapacityReject(p.ID, model)
	}
	p.Mu().Lock()
	p.SystemMetrics.ThermalState = "critical"
	p.Mu().Unlock()
	cc, capRej, tooLarge := r.QuickCapacityCheck(model, 10, 128, production.RequestTraits{})
	if cc != 0 || capRej != 0 || tooLarge != 0 {
		t.Fatalf("thermal-critical cooled pair = (cand=%d, rej=%d, tooLarge=%d), want 0/0/0", cc, capRej, tooLarge)
	}

	r2 := production.New(testLogger())
	r2.SetModelCatalog([]production.CatalogEntry{{ID: model, SizeGB: 128}})
	small := makeSchedulerProvider(t, r2, "small-box", model, 200)
	small.Mu().Lock()
	small.BackendCapacity.TotalMemoryGB = 24
	small.BackendCapacity.Slots[0].State = "idle_shutdown"
	small.Mu().Unlock()
	for i := 0; i < identitygate.LoadCapacityCooldownConfig().Threshold; i++ {
		r2.RecordCapacityReject(small.ID, model)
	}
	cc2, capRej2, tooLarge2 := r2.QuickCapacityCheck(model, 10, 128, production.RequestTraits{})
	if cc2 != 0 || capRej2 != 0 || tooLarge2 != 1 {
		t.Fatalf("undersized cooled pair = (cand=%d, rej=%d, tooLarge=%d), want 0/0/1", cc2, capRej2, tooLarge2)
	}
}

// Threshold-many rejects with no interleaved accepts trip exactly once.
func TestCapacityRejectBlackHoleTrips(t *testing.T) {
	r, gates := newCapacityCooldownRegistry(nil)
	const provider, model = "prov-blackhole", "gemma-4-26b-8bit"

	threshold := identitygate.LoadCapacityCooldownConfig().Threshold
	if threshold != 5 {
		t.Fatalf("default threshold = %d, want %d", threshold, 5)
	}

	for i := 1; i < threshold; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatalf("reject %d/%d tripped early", i, threshold)
		}
		if r.CapacityCooldownActive(provider, model) {
			t.Fatalf("cooldown active after only %d rejects", i)
		}
	}
	if tripped := r.RecordCapacityReject(provider, model); !tripped {
		t.Fatalf("reject %d did not trip the cooldown", threshold)
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown not active after trip")
	}
	// In-flight stragglers neither re-trip nor extend the deadline.
	expiry, _ := capacityCooldownExpiryOf(gates, provider, model)
	for i := 0; i < 3; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("straggler reject reported a second transition while cooling")
		}
	}
	if after, _ := capacityCooldownExpiryOf(gates, provider, model); !after.Equal(expiry) {
		t.Fatalf("straggler rejects extended the cooldown: %v -> %v", expiry, after)
	}
	if got, want := time.Until(expiry), 120*time.Second; got > want || got < want-5*time.Second {
		t.Fatalf("first-trip TTL ≈ %v, want ≈ %v", got, want)
	}
	if r.CapacityCooldownActive(provider, "other-model") {
		t.Fatal("cooldown leaked to a different model on the same provider")
	}
}

func TestCapacityAcceptClearsActiveCooldownAndBackoff(t *testing.T) {
	r, gates := newCapacityCooldownRegistry(nil)
	const provider, model = "prov-recover", "gemma-4-26b-8bit"
	threshold := identitygate.LoadCapacityCooldownConfig().Threshold

	for i := 0; i < threshold; i++ {
		r.RecordCapacityReject(provider, model)
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("setup: cooldown should be active")
	}
	r.RecordCapacityAccept(provider, model)
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("accept did not clear the active cooldown")
	}
	if trips := gates.ViewForSession(nil, provider).CapacityAssessment(model).Decision.Trips; trips != 0 {
		t.Fatalf("accept did not reset the trip count: %d", trips)
	}
	for i := 1; i < threshold; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatalf("post-accept reject %d re-tripped before the full threshold", i)
		}
	}
	if tripped := r.RecordCapacityReject(provider, model); !tripped {
		t.Fatal("full threshold after accept did not trip")
	}
	expiry, _ := capacityCooldownExpiryOf(gates, provider, model)
	if got, want := time.Until(expiry), 120*time.Second; got > want || got < want-5*time.Second {
		t.Fatalf("post-accept trip TTL ≈ %v, want base ≈ %v (backoff must have reset)", got, want)
	}
}

func TestCapacityCooldownExpiryReprobeAndExponentialBackoff(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r, gates := newCapacityCooldownRegistry(nil)
		const provider, model = "prov-repeat", "gemma-4-26b-8bit"
		cfg := identitygate.LoadCapacityCooldownConfig()

		for i := 0; i < cfg.Threshold; i++ {
			r.RecordCapacityReject(provider, model)
		}
		if !r.CapacityCooldownActive(provider, model) {
			t.Fatal("setup: first trip should be active")
		}

		wantTTL := cfg.BaseTTL
		for round := 0; round < 5; round++ {
			expiry, _ := capacityCooldownExpiryOf(gates, provider, model)
			time.Sleep(time.Until(expiry) + time.Second)
			if r.CapacityCooldownActive(provider, model) {
				t.Fatalf("round %d: expired cooldown still reads active — re-probe blocked", round)
			}
			if tripped := r.RecordCapacityReject(provider, model); !tripped {
				t.Fatalf("round %d: failed re-probe did not re-arm the cooldown", round)
			}
			wantTTL *= 2
			if wantTTL > cfg.MaxTTL {
				wantTTL = cfg.MaxTTL
			}
			expiry, ok := capacityCooldownExpiryOf(gates, provider, model)
			if !ok {
				t.Fatalf("round %d: no cooldown expiry after re-arm", round)
			}
			if got := time.Until(expiry); got > wantTTL || got < wantTTL-5*time.Second {
				t.Fatalf("round %d: backoff TTL ≈ %v, want ≈ %v", round, got, wantTTL)
			}
		}
		if wantTTL != cfg.MaxTTL {
			t.Fatalf("test walked %v but never reached the %v cap", wantTTL, cfg.MaxTTL)
		}
	})
}

func TestCapacityCooldownEnvTunables(t *testing.T) {
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD", "2")
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_WINDOW_SECONDS", "30")
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_TTL_SECONDS", "45")
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_MAX_TTL_SECONDS", "90")
	synctest.Test(t, func(t *testing.T) {
		r, gates := newCapacityCooldownRegistry(nil)
		cfg := identitygate.LoadCapacityCooldownConfig()
		want := identitygate.CapacityCooldownConfig{Threshold: 2, Window: 30 * time.Second, BaseTTL: 45 * time.Second, MaxTTL: 90 * time.Second}
		if cfg != want {
			t.Fatalf("config = %+v, want %+v", cfg, want)
		}

		const provider, model = "prov-env", "gemma-4-26b-8bit"
		if tripped := r.RecordCapacityReject(provider, model); tripped {
			t.Fatal("tripped on the first reject with threshold 2")
		}
		if tripped := r.RecordCapacityReject(provider, model); !tripped {
			t.Fatal("did not trip on the second reject with threshold 2")
		}
		expiry, _ := capacityCooldownExpiryOf(gates, provider, model)
		if got := time.Until(expiry); got > 45*time.Second || got < 40*time.Second {
			t.Fatalf("first-trip TTL ≈ %v, want ≈ 45s", got)
		}
		for round, wantTTL := range []time.Duration{90 * time.Second, 90 * time.Second} {
			expiry, _ := capacityCooldownExpiryOf(gates, provider, model)
			time.Sleep(time.Until(expiry) + time.Second)
			if tripped := r.RecordCapacityReject(provider, model); !tripped {
				t.Fatalf("round %d: failed re-probe did not re-arm", round)
			}
			expiry, _ = capacityCooldownExpiryOf(gates, provider, model)
			if got := time.Until(expiry); got > wantTTL || got < wantTTL-5*time.Second {
				t.Fatalf("round %d: TTL ≈ %v, want cap ≈ %v", round, got, wantTTL)
			}
		}
	})
}

func TestCapacityCooldownProbeClaimLifecycle(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r, gates := newCapacityCooldownRegistry(nil)
		const provider, model = "prov-probe", "gemma-4-26b-8bit"
		cfg := identitygate.LoadCapacityCooldownConfig()

		for i := 0; i < cfg.Threshold; i++ {
			r.RecordCapacityReject(provider, model)
		}
		if !r.CapacityCooldownActive(provider, model) {
			t.Fatal("setup: cooldown should be active")
		}

		expiry, _ := capacityCooldownExpiryOf(gates, provider, model)
		time.Sleep(time.Until(expiry) + time.Second)
		if r.CapacityCooldownActive(provider, model) {
			t.Fatal("expired unclaimed cooldown still reads active")
		}
		ref := gates.ResolveSession(provider, false)
		gates.ClaimCapacityProbe(ref, model, time.Now())
		if !r.CapacityCooldownActive(provider, model) {
			t.Fatal("gate open to the herd while the probe outcome is pending")
		}
		time.Sleep(30*time.Second + time.Second)
		if r.CapacityCooldownActive(provider, model) {
			t.Fatal("stale probe claim wedged the pair closed")
		}
		gates.ClaimCapacityProbe(ref, model, time.Now())
		if !r.RecordCapacityReject(provider, model) {
			t.Fatal("rejected probe did not re-arm the cooldown")
		}
		expiry, _ = capacityCooldownExpiryOf(gates, provider, model)
		if got, want := time.Until(expiry), 2*cfg.BaseTTL; got > want || got < want-5*time.Second {
			t.Fatalf("re-arm TTL ≈ %v, want doubled ≈ %v", got, want)
		}
		if !r.CapacityCooldownActive(provider, model) {
			t.Fatal("re-armed cooldown not active")
		}
		time.Sleep(time.Until(expiry) + time.Second)
		gates.ClaimCapacityProbe(ref, model, time.Now())
		r.RecordCapacityAccept(provider, model)
		if r.CapacityCooldownActive(provider, model) {
			t.Fatal("accepted probe did not clear the cooldown")
		}
		if trips := gates.ViewForSession(nil, provider).CapacityAssessment(model).Decision.Trips; trips != 0 {
			t.Fatalf("accepted probe did not reset the trip count: %d", trips)
		}
	})
}
