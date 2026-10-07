package registry_test

import (
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// An accept observed before the clamping reject must not prove release even
// when application is delayed until after a fresh heartbeat.
func TestCapacityAcceptObservedBeforeClampDoesNotProveRelease(t *testing.T) {
	r := production.New(testLogger())
	if !identitygate.LoadBudgetClampConfig().Enabled {
		t.Fatal("budget clamp disabled in the test environment")
	}
	const model = "gemma-4-26b-qat-4bit"
	p := makeTokenBudgetProvider(t, r, "gray-late-accept", model, 100, grayBoxBudgetUsed, grayBoxBudgetMax, 100)

	observedAt := time.Now()
	time.Sleep(2 * time.Millisecond)
	if r.RecordCapacityReject(p.ID, model) {
		t.Fatal("one reject must not trip the pair cooldown")
	}
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("clamp must be active after one capacity reject")
	}
	time.Sleep(2 * time.Millisecond)
	sendBudgetHeartbeat(r, p.ID, model, grayBoxBudgetUsed, grayBoxBudgetMax)
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("a fresh heartbeat alone must not release the clamp")
	}

	r.RecordCapacityAcceptObserved(p.ID, model, observedAt, true)
	if !r.BudgetClampActive(p.ID, model) {
		t.Fatal("an accept observed BEFORE the clamping reject released the clamp")
	}

	r.RecordCapacityAcceptObserved(p.ID, model, time.Now(), true)
	if r.BudgetClampActive(p.ID, model) {
		t.Fatal("fresh heartbeat + accept observed after the clamp must release it")
	}
}

// The later reject holds the real identity lock at its clock sample while the
// observed accept waits. Its post-observation strike must survive that accept.
func TestCapacityAcceptAppliedLateKeepsStrikeRecordedAfterObservation(t *testing.T) {
	const provider, model = "prov-late-accept", "gemma-4-26b-8bit"
	observedAt := time.Now()
	older := observedAt.Add(-time.Second)
	var sample atomic.Pointer[time.Time]
	sample.Store(&older)
	var holdNext atomic.Bool
	locked := make(chan struct{})
	release := make(chan time.Time)
	r, gates := newCapacityCooldownRegistry(func() time.Time {
		if holdNext.CompareAndSwap(true, false) {
			close(locked)
			return <-release
		}
		if at := sample.Load(); at != nil {
			return *at
		}
		return time.Now()
	})
	gates.RecordCapacityRejectProjected(provider, model, false, false, false)
	sample.Store(nil)
	holdNext.Store(true)
	rejected := make(chan struct{})
	go func() {
		defer close(rejected)
		gates.RecordCapacityRejectProjected(provider, model, false, false, false)
	}()
	<-locked
	applied := make(chan struct{})
	go func() {
		defer close(applied)
		r.RecordCapacityAcceptObserved(provider, model, observedAt, true)
	}()
	time.Sleep(2 * time.Millisecond)
	newer := time.Now()
	release <- newer
	<-rejected
	<-applied

	got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Strikes
	if len(got) != 1 || !got[0].Equal(newer) {
		t.Fatalf("strikes after a late-applied accept = %v, want exactly the strike recorded after the observation (%v)", got, newer)
	}

	threshold := identitygate.LoadCapacityCooldownConfig().Threshold
	for i := 2; i < threshold; i++ {
		if r.RecordCapacityReject(provider, model) {
			t.Fatalf("reject %d/%d tripped early", i, threshold)
		}
	}
	if !r.RecordCapacityReject(provider, model) {
		t.Fatalf("reject %d/%d did not trip: the strike recorded after the accept was not counted", threshold, threshold)
	}

	r.RecordCapacityAccept(provider, model)
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Strikes; len(got) != 0 {
		t.Fatalf("strikes after a current accept = %v, want none", got)
	}
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown still active after a current accept")
	}
}

func TestCapacityAcceptAppliedLateKeepsCooldownArmedByNewerStrikes(t *testing.T) {
	r, gates := newCapacityCooldownRegistry(nil)
	const provider, model = "prov-late-accept-tripped", "gemma-4-26b-8bit"
	threshold := identitygate.LoadCapacityCooldownConfig().Threshold

	observedAt := time.Now()
	time.Sleep(2 * time.Millisecond)
	for i := 1; i <= threshold; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped != (i == threshold) {
			t.Fatalf("reject %d/%d tripped=%v", i, threshold, tripped)
		}
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown not active after Threshold rejects")
	}

	r.RecordCapacityAcceptObserved(provider, model, observedAt, true)
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("a late-applied accept cleared a cooldown armed by strikes recorded after it")
	}
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Decision.Trips; got != 1 {
		t.Fatalf("trip count after the late accept = %d, want 1 (the backoff state survives with the cooldown)", got)
	}
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Strikes; len(got) != threshold {
		t.Fatalf("strikes after the late accept = %d, want all %d newer strikes", len(got), threshold)
	}

	r.RecordCapacityAccept(provider, model)
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown still active after a current accept")
	}
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Decision.Trips; got != 0 {
		t.Fatalf("trip count after a current accept = %d, want 0", got)
	}
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Strikes; len(got) != 0 {
		t.Fatalf("strikes after a current accept = %v, want none", got)
	}
}

func TestCapacityAcceptAppliedLateClearsCooldownTrippedWithOlderStrikes(t *testing.T) {
	r, gates := newCapacityCooldownRegistry(nil)
	const provider, model = "prov-late-accept-mixed", "gemma-4-26b-8bit"
	threshold := identitygate.LoadCapacityCooldownConfig().Threshold
	const newer = 2
	if threshold <= newer {
		t.Skipf("threshold %d leaves no room for older strikes", threshold)
	}

	for i := 1; i <= threshold-newer; i++ {
		if r.RecordCapacityReject(provider, model) {
			t.Fatalf("older reject %d tripped early", i)
		}
	}
	time.Sleep(2 * time.Millisecond)
	observedAt := time.Now()
	time.Sleep(2 * time.Millisecond)
	for i := 1; i <= newer; i++ {
		if tripped := r.RecordCapacityReject(provider, model); tripped != (i == newer) {
			t.Fatalf("newer reject %d/%d tripped=%v", i, newer, tripped)
		}
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("cooldown not active after Threshold rejects")
	}

	r.RecordCapacityAcceptObserved(provider, model, observedAt, true)
	if r.CapacityCooldownActive(provider, model) {
		t.Fatal("a cooldown that needed strikes from before the accept survived it")
	}
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Decision.Trips; got != 0 {
		t.Fatalf("trip count after the late accept = %d, want 0", got)
	}
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Strikes; len(got) != newer {
		t.Fatalf("strikes after the late accept = %d, want the %d recorded after the observation", len(got), newer)
	}

	for i := newer + 1; i < threshold; i++ {
		if r.RecordCapacityReject(provider, model) {
			t.Fatalf("reject %d/%d tripped early", i, threshold)
		}
	}
	if !r.RecordCapacityReject(provider, model) {
		t.Fatalf("reject %d/%d did not trip", threshold, threshold)
	}
	if got := gates.ViewForSession(nil, provider).CapacityAssessment(model).Decision.Trips; got != 1 {
		t.Fatalf("trip count after the re-trip = %d, want 1 (fresh backoff)", got)
	}
}

// Exercise the production rebuild calculation with the original pre-accept
// backoff, then verify the real accept applies that same fresh decision.
func TestCapacityAcceptRebuildsNewCooldownWithFreshBackoff(t *testing.T) {
	for _, active := range []bool{false, true} {
		t.Run(fmt.Sprintf("old_active_%v", active), func(t *testing.T) {
			r, gates := newCapacityCooldownRegistry(nil)
			const provider, model = "old-backoff", "model"
			observed := time.Now().Add(-time.Second)
			oldExpiry := time.Now().Add(-time.Second)
			if active {
				oldExpiry = time.Now().Add(5 * time.Minute)
			}
			previous := identitygate.CooldownDecision{RetryAfter: oldExpiry, Trips: 4}
			cfg := identitygate.LoadCapacityCooldownConfig()
			for range cfg.Threshold {
				r.RecordCapacityReject(provider, model)
			}
			strikes := gates.ViewForSession(nil, provider).CapacityAssessment(model).Strikes
			wantExpiry := strikes[cfg.Threshold-1].Add(cfg.BaseTTL)
			got := identitygate.RebuildCapacityCooldown(cfg, strikes, previous)
			r.RecordCapacityAcceptObserved(provider, model, observed, true)
			applied := gates.ViewForSession(nil, provider).CapacityAssessment(model).Decision
			if got.Trips != 1 || !got.RetryAfter.Equal(wantExpiry) {
				t.Fatalf("rebuilt cooldown: trips=%d expiry=%v, want 1/%v", got.Trips, got.RetryAfter, wantExpiry)
			}
			if applied != got {
				t.Fatalf("applied cooldown = %+v, want rebuilt decision %+v", applied, got)
			}
		})
	}
}

func TestCapacityAcceptRebuildPreservesNewProbe(t *testing.T) {
	const provider, model = "probe", "model"
	now := time.Now()
	cfg := identitygate.CapacityCooldownConfig{Threshold: 2, Window: time.Minute, BaseTTL: time.Second, MaxTTL: time.Minute}
	strikes := []time.Time{now.Add(-4 * time.Second), now.Add(-3 * time.Second)}
	probeAt := now.Add(-time.Second)
	previous := identitygate.CooldownDecision{RetryAfter: now.Add(-2 * time.Second), ProbeAt: probeAt, Trips: 4}
	rebuilt := identitygate.RebuildCapacityCooldown(cfg, strikes, previous)

	// Feed the same two strike timestamps and probe through the retained owner;
	// the pure call above separately pins the original four-trip prehistory.
	options := identitygate.DefaultOptions()
	options.CapacityCooldown = cfg
	at := strikes[0]
	options.Now = func() time.Time { return at }
	gates := identitygate.New(nil, &options)
	r := production.NewWithDependencies(nil, production.Dependencies{IdentityGates: gates})
	for _, at = range strikes {
		gates.RecordCapacityRejectProjected(provider, model, false, false, false)
	}
	gates.ClaimCapacityProbe(gates.ResolveSession(provider, false), model, probeAt)
	at = now
	r.RecordCapacityAcceptObserved(provider, model, now.Add(-5*time.Second), false)
	assessment := gates.ViewForSession(nil, provider).CapacityAssessment(model)
	if entry := assessment.Decision; !assessment.Present || !entry.ProbeAt.Equal(probeAt) {
		t.Fatalf("lost current probe: %+v", entry)
	}
	if !r.CapacityCooldownActive(provider, model) {
		t.Fatal("rebuild allowed a second probe while the first is pending")
	}
	if assessment.Decision != rebuilt {
		t.Fatalf("applied probe decision = %+v, want rebuilt decision %+v", assessment.Decision, rebuilt)
	}
}
