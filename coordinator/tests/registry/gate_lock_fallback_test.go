package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
)

func TestVanishedClearRefLeavesLiveSiblingGateUntouched(t *testing.T) {
	for _, tc := range []struct {
		name    string
		retries int
	}{{"optimistic", 0}, {"retry-exhaustion", 4}} {
		t.Run(tc.name, func(t *testing.T) {
			reg, gates, clock := newFaultGateFixture()
			const model = "m"
			p1 := makeSchedulerProvider(t, reg, "vanished-clear-1", model, 100)
			p2 := makeSchedulerProvider(t, reg, "vanished-clear-2", model, 100)
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-VANISHED-CLEAR"}
			p1.SetAttestationResult(identity)
			p2.SetAttestationResult(identity)
			reg.RecordDispatchLoadFailure(p1.ID, model)
			ref, has := gates.PrepareDispatchLoadClear(gates.ResolveSession(p1.ID, false))
			if !has || !gates.ViewReference(ref).SameIdentity(gates.ViewForSession(nil, p2.ID)) {
				t.Fatal("precondition: clear must have observed the shared gate's state")
			}
			shared := gates.ViewReference(ref)

			// Interpose after the clear's lookup. The shared gate remains live
			// for p2, while p1's new anonymous session gate disappears entirely.
			p1.SetAttestationResult(nil)
			reg.Disconnect(p1.ID)
			reg.RecordDispatchLoadFailure(p2.ID, model)
			if gates.ViewReference(gates.ResolveSession(p1.ID, false)).Present() {
				t.Fatal("precondition: the cleared session must no longer resolve")
			}

			budget := identitygate.NewRetryBudget()
			for i := 0; i < tc.retries; i++ {
				budget.Step()
			}
			applied := gates.ClearDispatchLoadCooldownRef(ref, model, budget)
			if applied.Present() {
				t.Fatalf("vanished clear returned gate %q; it could erase a sibling's fresh fault", gates.FaultKeyForSession(p1.ID))
			}
			if !gates.ViewForSession(nil, p2.ID).SameIdentity(shared) || !gates.ViewForSession(nil, p2.ID).DispatchLoadCooled(model, clock.Now()) {
				t.Fatal("vanished session's clear disturbed the live sibling's cooldown")
			}
			if gates.ViewIdentity(p1.ID).Present() {
				t.Fatal("a no-insert clear recreated the vanished session gate")
			}
		})
	}
}

func TestGateRetryExhaustionLocksCurrentSharedBinding(t *testing.T) {
	reg, gates, clock := newFaultGateFixture()
	p1 := makeSchedulerProvider(t, reg, "exhausted-bind-1", "m", 100)
	p2 := makeSchedulerProvider(t, reg, "exhausted-bind-2", "m", 100)
	identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-EXHAUSTED-BIND"}
	p1.SetAttestationResult(identity)
	p2.SetAttestationResult(identity)
	ref := gates.ResolveSession(p1.ID, true)
	shared := gates.ViewReference(ref)
	p1.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: identity.PublicKey, SerialNumber: "SER-EXHAUSTED-BIND",
	})
	target := gates.ViewForSession(nil, p1.ID)
	if target.SameIdentity(shared) || !gates.ViewForSession(nil, p2.ID).SameIdentity(shared) {
		t.Fatal("precondition: only the recording session must change gates")
	}

	// Enter with the optimistic budget consumed, the same state reached after
	// repeated rebinds. Exhaustion must not waive currentLocked's invariant.
	budget := identitygate.NewRetryBudget()
	for i := 0; i < 4; i++ {
		budget.Step()
	}
	applied, _, _ := gates.RecordProviderOutcomeResolved(ref, budget, false, 500, "internal error")
	if !applied.SameIdentity(target) {
		t.Fatal("retry exhaustion returned the live sibling's obsolete gate")
	}
	for i := 1; i < providerBreakerConsecTrip; i++ {
		gates.RecordProviderOutcomeResolved(ref, budget, false, 500, "internal error")
	}
	if gates.ViewForSession(nil, p1.ID).BreakerHealth(clock.Now()).Trips != 1 || gates.ViewForSession(nil, p2.ID).BreakerHealth(clock.Now()).Trips != 0 {
		t.Fatal("record after retry exhaustion landed on the wrong identity")
	}
}

func TestGateRetryExhaustionRecreatesRetiredIdentity(t *testing.T) {
	_, gates, clock := newFaultGateFixture()
	const key = "serial:SER-EXHAUSTED-SWEEP"
	now := clock.Now()
	clock.Set(now.Add(-gateIdleGrace - time.Minute))
	ref := gates.ResolveIdentity(key)
	clock.Set(now)
	report := gates.Maintain(now)
	if gates.ViewIdentity(key).Present() {
		t.Fatal("precondition: identity must have been swept")
	}
	budget := identitygate.NewRetryBudget()
	for i := 0; i < 4; i++ {
		budget.Step()
	}
	applied, _, _ := gates.RecordProviderOutcomeResolved(ref, budget, false, 500, "internal error")
	if !applied.Present() || applied.SameIdentity(gates.ViewReference(ref)) || report.Retired != 1 || gates.Maintain(now).RetiredIndexed != 0 {
		t.Fatal("retry exhaustion returned the retired identity gate")
	}
	current := applied
	for i := 1; i < providerBreakerConsecTrip; i++ {
		gates.RecordProviderOutcomeResolved(ref, budget, false, 500, "internal error")
	}
	if !gates.ViewIdentity(key).SameIdentity(current) {
		t.Fatal("recorded gate is absent from the current index")
	}
}
