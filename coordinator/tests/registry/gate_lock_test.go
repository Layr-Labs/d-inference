package registry_test

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type gateRecorderLoadLifecycle struct {
	warmplan.LoadState
	entered chan struct{}
	release chan struct{}
}

func (l *gateRecorderLoadLifecycle) Reset() {
	close(l.entered)
	<-l.release
	l.LoadState.Reset()
}

// An accept on the first-byte path must not queue behind the registry write
// lock: with the lock held for writing by someone else, the recorders still run.
func TestRecordersDoNotTakeTheRegistryWriteLock(t *testing.T) {
	holder := &gateRecorderLoadLifecycle{entered: make(chan struct{}), release: make(chan struct{})}
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		WarmLifecycle: func(id string) warmplan.LoadLifecycle {
			if id == "registry-lock-holder" {
				return holder
			}
			return new(warmplan.LoadState)
		},
	})
	p := attestSchedulerProvider(t, reg, "sess-nolock", "m", "SER-NOLOCK", 100)
	makeSchedulerProvider(t, reg, "registry-lock-holder", "m", 100)
	lockReleased := make(chan struct{})
	go func() {
		defer close(lockReleased)
		// Disconnect resets this independent lifecycle under the registry write
		// lock, before it acquires the session-directory lock.
		reg.Disconnect("registry-lock-holder")
	}()
	<-holder.entered
	defer func() {
		close(holder.release)
		<-lockReleased
	}()
	done := make(chan struct{})
	go func() {
		defer close(done)
		reg.RecordCapacityAccept(p.ID, "m")
		reg.RecordInferenceSuccess(p.ID, "m", "base")
		reg.RecordProviderOutcome(p.ID, true, 200, "")
		reg.RecordProviderServeOutcome("serial:SER-NOLOCK", true, 200, "")
		reg.ClearDispatchLoadCooldown(p.ID, "m")
		reg.RecordDispatchLoadFailure(p.ID, "m")
		reg.RecordInferenceError(p.ID, "m", 500, "base")
		reg.RecordCapacityReject(p.ID, "m")
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a recorder blocked behind the registry write lock")
	}
}

// Two sessions of one identity racing for the single half-open probe: the
// check-and-claim under the identity lock lets exactly one through, and the
// gate reads closed for both afterwards.
func TestTryClaimCapacityProbeIsExclusivePerIdentity(t *testing.T) {
	now := time.Now()
	options := identitygate.DefaultOptions()
	options.Now = func() time.Time { return now }
	gates := identitygate.New(testLogger(), &options)
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	const model = "m"
	p1 := attestSchedulerProvider(t, reg, "sess-probe-1", model, "SER-PROBE", 100)
	p2 := attestSchedulerProvider(t, reg, "sess-probe-2", model, "SER-PROBE", 100)
	view1 := gates.ViewReference(gates.ResolveSession(p1.ID, false))
	view2 := gates.ViewReference(gates.ResolveSession(p2.ID, false))
	if !view1.SameIdentity(view2) {
		t.Fatal("sessions of one identity must share a gate")
	}
	for i := 0; i < options.CapacityCooldown.Threshold; i++ {
		reg.RecordCapacityReject(p1.ID, model)
	}
	if !view2.CapacityCooled(model, now) {
		t.Fatal("the cooldown must be visible through the sibling session")
	}
	// Move the policy clock past the real cooldown instead of mutating expiry.
	now = now.Add(options.CapacityCooldown.BaseTTL + time.Second)
	if view1.CapacityCooled(model, now) {
		t.Fatal("an expired, unclaimed cooldown must read open")
	}

	var claimed atomic.Int32
	var wg sync.WaitGroup
	for _, p := range []*production.Provider{p1, p2, p1, p2} {
		wg.Add(1)
		go func(p *production.Provider) {
			defer wg.Done()
			if gates.ClaimCapacityProbe(gates.ResolveSession(p.ID, false), model, now) {
				claimed.Add(1)
			}
		}(p)
	}
	wg.Wait()
	if claimed.Load() != 1 {
		t.Fatalf("probe claims = %d, want exactly 1", claimed.Load())
	}
	if !view1.CapacityCooled(model, now) || !view2.CapacityCooled(model, now) {
		t.Fatal("the claimed probe must close the gate for every session of the identity")
	}
	// No cooldown entry at all: the claim is a lock-free no-op that admits.
	if !gates.ClaimCapacityProbe(gates.ResolveSession(p1.ID, false), "other-model", now) {
		t.Fatal("a pair with no cooldown entry must always claim")
	}
}

// A gate.mu wait above the threshold reaches the observer tagged by site — and
// only then: uncontended recorders report nothing.
func TestGateWaitObserverReportsLongWaits(t *testing.T) {
	var block atomic.Bool
	entered := make(chan struct{})
	release := make(chan struct{})
	options := identitygate.DefaultOptions()
	options.Now = func() time.Time {
		if block.CompareAndSwap(true, false) {
			close(entered)
			<-release
		}
		return time.Now()
	}
	gates := identitygate.New(testLogger(), &options)
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	p := makeSchedulerProvider(t, reg, "sess-wait", "m", 100)
	type seen struct {
		site string
		wait time.Duration
	}
	var mu sync.Mutex
	var got []seen
	reg.SetGateWaitObserver(func(site string, wait time.Duration) {
		mu.Lock()
		got = append(got, seen{site, wait})
		mu.Unlock()
	})

	reg.RecordProviderOutcome(p.ID, true, 200, "")
	mu.Lock()
	n := len(got)
	mu.Unlock()
	if n != 0 {
		t.Fatalf("uncontended recorder reported a wait: %+v", got)
	}

	// The neutral shed samples its clock under the real recorder lock without
	// changing the health history that the contending success will observe.
	block.Store(true)
	held := make(chan struct{})
	go func() {
		defer close(held)
		reg.RecordProviderOutcome(p.ID, false, 429, "")
	}()
	<-entered
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(release)
	}()
	reg.RecordProviderOutcome(p.ID, true, 200, "")
	<-held
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 1 || got[0].site != "breaker" || got[0].wait < 5*time.Millisecond {
		t.Fatalf("observer calls = %+v, want one 'breaker' wait of >= 5ms", got)
	}
	reg.SetGateWaitObserver(nil)
}

// A reference captured from a shared identity follows its own session's rebind,
// while the sibling's reference continues recording on the shared identity.
func TestStaleRefFollowsSharedIdentityRebind(t *testing.T) {
	reg, gates, clock := newFaultGateFixture()
	p1 := makeSchedulerProvider(t, reg, "sess-rebind-1", "m", 100)
	p2 := makeSchedulerProvider(t, reg, "sess-rebind-2", "m", 100)
	pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-REBIND"}
	p1.SetAttestationResult(pk)
	p2.SetAttestationResult(pk)
	shared := gates.ViewIdentity("sekey:PK-REBIND")
	if !shared.Present() || !gates.ViewForSession(nil, p1.ID).SameIdentity(shared) || !gates.ViewForSession(nil, p2.ID).SameIdentity(shared) {
		t.Fatal("both sessions must share the identity's gate")
	}
	reg.RecordProviderOutcome(p1.ID, false, 500, "internal error")

	ref1 := gates.ResolveSession(p1.ID, true)
	ref2 := gates.ResolveSession(p2.ID, true)
	if !gates.ViewReference(ref1).SameIdentity(shared) || !ref1.IsLive() || !gates.ViewReference(ref2).SameIdentity(shared) || !ref2.IsLive() {
		t.Fatalf("refs = %+v / %+v, want the shared gate via each session", ref1, ref2)
	}
	p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-REBIND", SerialNumber: "SER-REBIND"})
	target := gates.ViewForSession(nil, p1.ID)
	if target.SameIdentity(shared) || !target.MatchesIdentity("serial:SER-REBIND") {
		t.Fatalf("p1's gate after the rebind = %+v, want serial:SER-REBIND", target)
	}
	if _, advanced := shared.FollowMigration(); advanced || !gates.ViewIdentity("sekey:PK-REBIND").SameIdentity(shared) {
		t.Fatal("precondition: the shared gate stays in the index, unforwarded, for p2")
	}
	if !target.BreakerHealth(clock.Now()).HasHistory || shared.BreakerHealth(clock.Now()).HasHistory {
		t.Fatal("precondition: the fault history moved to the enriched identity")
	}

	applied, _, _ := gates.RecordProviderOutcomeResolved(ref1, identitygate.NewRetryBudget(), false, 500, "internal error")
	if !applied.SameIdentity(target) {
		t.Fatalf("p1's recorder locked %q, want the session's new gate serial:SER-REBIND", gates.FaultKeyForSession(p1.ID))
	}
	for i := 2; i < providerBreakerConsecTrip; i++ {
		gates.RecordProviderOutcomeRef(ref1, false, 500, "internal error")
	}
	if got := gates.ViewForSession(nil, p1.ID).BreakerHealth(clock.Now()).Trips; got != 1 {
		t.Fatalf("p1's outcome did not land on its identity: trips=%d", got)
	}
	if g := gates.ViewIdentity("sekey:PK-REBIND"); !g.Present() || g.BreakerHealth(clock.Now()).Trips != 0 || g.BreakerHealth(clock.Now()).HasHistory {
		t.Fatalf("p2's identity must be untouched by p1's stale recorder: %+v", g)
	}

	applied, _, _ = gates.RecordProviderOutcomeResolved(ref2, identitygate.NewRetryBudget(), false, 500, "internal error")
	if !applied.SameIdentity(shared) {
		t.Fatalf("p2's recorder locked %q, want its own (shared) gate", gates.FaultKeyForSession(p2.ID))
	}
	if !shared.BreakerHealth(clock.Now()).HasHistory || gates.ViewForSession(nil, p2.ID).BreakerHealth(clock.Now()).Trips != 0 {
		t.Fatal("p2's outcome must land on p2's identity, and only there")
	}
}

// A delayed outcome must recreate a swept identity rather than mutate its
// retired state, whether resolved by disconnected session or stable identity.
func TestStaleRefSurvivesSweepOfDisconnectedGate(t *testing.T) {
	const key = "serial:SER-SWEEP-RACE"
	for _, tc := range []struct {
		name    string
		resolve func(gates *identitygate.Directory, sessionID string) identitygate.Reference
	}{
		{"by session through the disconnect cache", func(gates *identitygate.Directory, sessionID string) identitygate.Reference {
			return gates.ResolveSession(sessionID, true)
		}},
		{"by stable id", func(gates *identitygate.Directory, _ string) identitygate.Reference {
			return gates.ResolveIdentity(key)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg, gates, clock := newFaultGateFixture()
			p := attestSchedulerProvider(t, reg, "sess-sweep-race", "m", "SER-SWEEP-RACE", 100)
			reg.Disconnect(p.ID)
			// A neutral shed dates the idle gate without adding fault history or
			// backdating the disconnect cache needed by the trailing outcome.
			now := clock.Now()
			clock.Set(now.Add(-gateIdleGrace - time.Minute))
			reg.RecordProviderOutcome(p.ID, false, 429, "")
			clock.Set(now)

			ref := tc.resolve(gates, p.ID)
			stale := gates.ViewReference(ref)
			if !stale.Present() || !stale.MatchesIdentity(key) || ref.IsLive() {
				t.Fatalf("pre-sweep ref = %+v, want the disconnected identity's gate with no live session", ref)
			}
			report := gates.Maintain(now)
			if gates.ViewIdentity(key).Present() {
				t.Fatal("precondition: the sweep must drop the idle disconnected gate")
			}

			applied, _, _ := gates.RecordProviderOutcomeResolved(ref, identitygate.NewRetryBudget(), false, 500, "internal error")
			if applied.SameIdentity(stale) {
				t.Fatal("lockGate handed out the gate the sweep retired")
			}
			if !applied.MatchesIdentity(key) || !gates.ViewIdentity(key).SameIdentity(applied) {
				t.Fatalf("re-resolved to %q (in index: %v), want a fresh %s gate", gates.FaultKeyForSession(p.ID), gates.ViewIdentity(key).SameIdentity(applied), key)
			}
			if report.Retired != 1 || report.RetiredIndexed != 0 || stale.BreakerHealth(now).HasHistory {
				t.Fatal("the swept gate must be marked retired under its lock")
			}
			if !gates.ViewIdentity(key).BreakerHealth(now).HasHistory {
				t.Fatal("the trailing fault must be on the gate a fresh lookup finds")
			}
			for i := 1; i < providerBreakerConsecTrip; i++ {
				reg.RecordProviderOutcome(p.ID, false, 502, "provider disconnected")
			}
			if !reg.ProviderBreakerOpen(p.ID) {
				t.Fatal("the identity's breaker must be open through the disconnected session id")
			}
		})
	}
}

func TestClearRefNeverFilesAGateForASweptIdentity(t *testing.T) {
	const key = "serial:SER-CLEAR-RACE"
	reg, gates, clock := newFaultGateFixture()
	p := attestSchedulerProvider(t, reg, "sess-clear-race", "m", "SER-CLEAR-RACE", 100)
	reg.Disconnect(p.ID)
	now := clock.Now()
	clock.Set(now.Add(-gateIdleGrace - time.Minute))
	reg.RecordProviderOutcome(p.ID, false, 429, "")
	clock.Set(now)

	ref := gates.ResolveSession(p.ID, false)
	stale := gates.ViewReference(ref)
	if !stale.Present() || !stale.MatchesIdentity(key) || ref.IsLive() {
		t.Fatalf("pre-sweep lookup ref = %+v, want a no-insert ref to the identity's gate", ref)
	}
	gates.Maintain(now)
	if gates.ViewIdentity(key).Present() {
		t.Fatal("precondition: the sweep must drop the idle disconnected gate")
	}
	applied := gates.ClearDispatchLoadCooldownRef(ref, "m", identitygate.NewRetryBudget())
	if applied.Present() {
		t.Fatalf("a clear re-resolved to %q; it must return a no-op hold", gates.FaultKeyForSession(p.ID))
	}
	if gates.ViewIdentity(key).Present() || gates.ViewIdentity(p.ID).Present() {
		t.Fatal("a clear must not file a gate for a swept identity or a dead session")
	}
	reg.ClearDispatchLoadCooldown(p.ID, "m")
	reg.RecordInferenceSuccess(p.ID, "m", "base")
	if count := gates.Maintain(now).Retained; count != 0 {
		t.Fatalf("gate index after a straggling clear = %d, want 0", count)
	}
}

func TestProbeClaimFollowsSharedIdentityRebind(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode string) {
		t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", mode)
		reg, gates, clock := newFaultGateFixture()
		const model = "m"
		p1 := makeSchedulerProvider(t, reg, "sess-probe-rebind-1", model, 100)
		p2 := makeSchedulerProvider(t, reg, "sess-probe-rebind-2", model, 100)
		pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-PROBE-REBIND"}
		p1.SetAttestationResult(pk)
		p2.SetAttestationResult(pk)
		shared := gates.ViewIdentity("sekey:PK-PROBE-REBIND")
		if !shared.Present() || !gates.ViewForSession(nil, p1.ID).SameIdentity(shared) || !gates.ViewForSession(nil, p2.ID).SameIdentity(shared) {
			t.Fatal("both sessions must share the identity's gate")
		}
		cfg := identitygate.DefaultOptions().CapacityCooldown
		for i := 0; i < cfg.Threshold; i++ {
			reg.RecordCapacityReject(p1.ID, model)
		}
		clock.Advance(cfg.BaseTTL + time.Second)
		if shared.CapacityCooled(model, clock.Now()) {
			t.Fatal("precondition: an expired, unclaimed cooldown must read open")
		}

		ref := gates.ResolveSession(p1.ID, false)
		if !gates.ViewReference(ref).SameIdentity(shared) || !ref.IsLive() {
			t.Fatalf("probe ref = %+v, want the shared gate via p1", ref)
		}
		p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-PROBE-REBIND", SerialNumber: "SER-PROBE-REBIND"})
		target := gates.ViewForSession(nil, p1.ID)
		if target.SameIdentity(shared) || !target.MatchesIdentity("serial:SER-PROBE-REBIND") {
			t.Fatalf("p1's gate after the rebind = %+v, want serial:SER-PROBE-REBIND", target)
		}
		if !target.CapacityAssessment(model).Present || shared.CapacityAssessment(model).Present {
			t.Fatal("precondition: the cooldown entry moved with the session")
		}

		now := clock.Now()
		if !gates.ClaimCapacityProbe(ref, model, now) {
			t.Fatal("the expired, unclaimed probe must be claimable")
		}
		g := gates.ViewIdentity("serial:SER-PROBE-REBIND")
		if !g.Present() {
			t.Fatal("the enriched identity's gate must exist")
		}
		if e := g.CapacityAssessment(model); !e.Present || !e.Decision.ProbeAt.Equal(now) {
			t.Fatalf("the claim must land on the session's new gate: entry=%+v", e)
		}
		g = gates.ViewIdentity("sekey:PK-PROBE-REBIND")
		if !g.Present() {
			t.Fatal("the shared gate must stay in the index for p2")
		}
		if e := g.CapacityAssessment(model); e.Present {
			t.Fatalf("the other identity's state must be untouched by the stale claim: %+v", e)
		}
		if !gates.ViewForSession(nil, p1.ID).CapacityCooled(model, now) {
			t.Fatal("the claimed probe must close the gate for p1's identity")
		}
		if gates.ViewForSession(nil, p2.ID).CapacityCooled(model, now) {
			t.Fatal("p2's identity carries no cooldown after the migration")
		}
		if gates.ClaimCapacityProbe(gates.ResolveSession(p1.ID, false), model, now) {
			t.Fatal("a second claim must see the fresh claim and reject")
		}
	})
}

func TestRefHasPairStateFollowsSharedIdentityRebind(t *testing.T) {
	reg, gates, clock := newFaultGateFixture()
	const model = "m"
	p1 := makeSchedulerProvider(t, reg, "sess-flag-rebind-1", model, 100)
	p2 := makeSchedulerProvider(t, reg, "sess-flag-rebind-2", model, 100)
	pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-FLAG-REBIND"}
	p1.SetAttestationResult(pk)
	p2.SetAttestationResult(pk)
	shared := gates.ViewIdentity("sekey:PK-FLAG-REBIND")
	reg.RecordDispatchLoadFailure(p1.ID, model)

	ref := gates.ResolveSession(p1.ID, false)
	if !gates.ViewReference(ref).SameIdentity(shared) || !ref.IsLive() || !shared.DispatchLoadCooled(model, clock.Now()) {
		t.Fatalf("pre-rebind ref = %+v, want the shared gate (with dispatch-load state) via p1", ref)
	}
	p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-FLAG-REBIND", SerialNumber: "SER-FLAG-REBIND"})
	target := gates.ViewForSession(nil, p1.ID)
	if target.SameIdentity(shared) || shared.DispatchLoadCooled(model, clock.Now()) || !target.DispatchLoadCooled(model, clock.Now()) {
		t.Fatal("precondition: the dispatch-load cooldown moved with the session and the shared gate reads empty")
	}

	got, has := gates.PrepareDispatchLoadClear(ref)
	if !has || !gates.ViewReference(got).SameIdentity(target) || !got.IsLive() {
		t.Fatalf("refHasPairState = (%+v, %v), want the session's new gate with state", got, has)
	}
	reg.ClearDispatchLoadCooldown(p1.ID, model)
	if gates.ViewForSession(nil, p1.ID).DispatchLoadCooled(model, clock.Now()) {
		t.Fatal("the clear must land on the session's new gate")
	}
	got, has = gates.PrepareDispatchLoadClear(gates.ResolveSession(p2.ID, false))
	if has || !gates.ViewReference(got).SameIdentity(shared) {
		t.Fatalf("refHasPairState on p2's empty gate = (%+v, %v), want (shared, false)", got, has)
	}
}
