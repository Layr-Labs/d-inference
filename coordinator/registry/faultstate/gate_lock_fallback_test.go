package faultstate

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestGateRetryExhaustionRecreatesRetiredIdentity(t *testing.T) {
	reg := newTestManager(testLogger())
	const key = "serial:SER-EXHAUSTED-SWEEP"
	ref := reg.gateForKey(key)
	withGateForKey(reg, key, func(g *gateState) {
		g.touched = time.Now().Add(-gateIdleGrace - time.Minute)
	})
	reg.sweepGates(time.Now())
	if rawGateForKey(reg, key) != nil {
		t.Fatal("precondition: identity must have been swept")
	}
	hold := reg.lockGateWithRetries(ref, "health_ejection", gateRelockMaxRetries)
	if hold.g == nil || hold.g == ref.g || hold.g.retired {
		hold.unlock()
		t.Fatal("retry exhaustion returned the retired identity gate")
	}
	current := hold.g
	hold.g.breakerTrips++
	hold.g.updatedLocked(time.Now())
	hold.unlock()
	if rawGateForKey(reg, key) != current {
		t.Fatal("recorded gate is absent from the current index")
	}
}

func TestVanishedClearRefLeavesLiveSiblingGateUntouched(t *testing.T) {
	for _, tc := range []struct {
		name    string
		retries int
	}{{"optimistic", 0}, {"retry-exhaustion", gateRelockMaxRetries}} {
		t.Run(tc.name, func(t *testing.T) {
			reg := newTestManager(testLogger())
			const model = "m"
			p1 := attachTestSession(reg, "vanished-clear-1")
			p2 := attachTestSession(reg, "vanished-clear-2")
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-VANISHED-CLEAR"}
			bindTestIdentity(reg, p1, identity)
			bindTestIdentity(reg, p2, identity)
			reg.RecordDispatchLoadFailure(p1.id, model)
			ref, has := reg.refHasPairState(reg.lookupSessionGateRef(p1.id), gateFlagDispatchLoad)
			if !has || ref.g != p2.gate.Load() {
				t.Fatal("precondition: clear must have observed the shared gate's state")
			}
			shared := ref.g

			// Interpose after the clear's lookup. The shared gate remains live
			// for p2, while p1's new anonymous session gate disappears entirely.
			bindTestIdentity(reg, p1, nil)
			detachTestSession(reg, p1.id)
			reg.RecordDispatchLoadFailure(p2.id, model)
			if reg.lookupSessionGateRef(p1.id).g != nil {
				t.Fatal("precondition: the cleared session must no longer resolve")
			}

			hold := reg.lockGateWithRetries(ref, "dispatch_load_clear", tc.retries)
			if hold.g != nil {
				hold.unlock()
				t.Fatalf("vanished clear returned gate %q; it could erase a sibling's fresh fault", hold.g.key)
			}
			hold.unlock() // A missing identity's hold is safe to release.
			if p2.gate.Load() != shared || !reg.dispatchLoadCooled(p2.id, model, time.Now()) {
				t.Fatal("vanished session's clear disturbed the live sibling's cooldown")
			}
			if rawGateForKey(reg, p1.id) != nil {
				t.Fatal("a no-insert clear recreated the vanished session gate")
			}
		})
	}
}

func TestGateRetryExhaustionLocksCurrentSharedBinding(t *testing.T) {
	reg := newTestManager(testLogger())
	p1 := attachTestSession(reg, "exhausted-bind-1")
	p2 := attachTestSession(reg, "exhausted-bind-2")
	identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-EXHAUSTED-BIND"}
	bindTestIdentity(reg, p1, identity)
	bindTestIdentity(reg, p2, identity)
	ref := reg.gateForSession(p1.id)
	shared := ref.g
	bindTestIdentity(reg, p1, &attestation.VerificationResult{
		Valid: true, PublicKey: identity.PublicKey, SerialNumber: "SER-EXHAUSTED-BIND",
	})
	target := p1.gate.Load()
	if target == shared || p2.gate.Load() != shared {
		t.Fatal("precondition: only the recording session must change gates")
	}

	// Enter with the optimistic budget consumed, the same state reached after
	// repeated rebinds. Exhaustion must not waive currentLocked's invariant.
	hold := reg.lockGateWithRetries(ref, "breaker", gateRelockMaxRetries)
	if hold.g != target {
		hold.unlock()
		t.Fatal("retry exhaustion returned the live sibling's obsolete gate")
	}
	hold.g.breakerTrips++
	hold.g.updatedLocked(time.Now())
	hold.unlock()
	if providerBreakerTripsOf(reg, p1.id) != 1 || providerBreakerTripsOf(reg, p2.id) != 0 {
		t.Fatal("record after retry exhaustion landed on the wrong identity")
	}
}
