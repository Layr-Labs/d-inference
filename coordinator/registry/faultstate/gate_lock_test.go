package faultstate

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// A recorder that resolved a gate SHARED by two sessions just before one of
// them rebinds (sekey: → serial: enrichment) must land its outcome on the
// rebinding session's NEW gate — the shared gate stays in the index for the
// other session, carries no forward, and was emptied by the migration, so
// only the session's own repointed p.gate can tell the stale holder to move.
// The other session's recorder, resolved at the same moment, stays put.
func TestStaleRefFollowsSharedIdentityRebind(t *testing.T) {
	reg := newTestManager(testLogger())
	p1 := attachTestSession(reg, "sess-rebind-1")
	p2 := attachTestSession(reg, "sess-rebind-2")
	pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-REBIND"}
	bindTestIdentity(reg, p1, pk)
	bindTestIdentity(reg, p2, pk)
	shared := reg.lookupGateForKey("sekey:PK-REBIND")
	if shared == nil || p1.gate.Load() != shared || p2.gate.Load() != shared {
		t.Fatal("both sessions must share the identity's gate")
	}
	reg.RecordProviderOutcome(p1.id, false, 500, "internal error")

	// Two recorders resolve the shared gate, one per session...
	ref1 := reg.gateForSession(p1.id)
	ref2 := reg.gateForSession(p2.id)
	if ref1.g != shared || ref1.p != p1 || ref2.g != shared || ref2.p != p2 {
		t.Fatalf("refs = %+v / %+v, want the shared gate via each session", ref1, ref2)
	}
	// ...and p1 enriches to a serial before either takes the lock.
	bindTestIdentity(reg, p1, &attestation.VerificationResult{Valid: true, PublicKey: "PK-REBIND", SerialNumber: "SER-REBIND"})
	target := p1.gate.Load()
	if target == shared || target.key != "serial:SER-REBIND" {
		t.Fatalf("p1's gate after the rebind = %+v, want serial:SER-REBIND", target)
	}
	if shared.forwardTo.Load() != nil || rawGateForKey(reg, "sekey:PK-REBIND") != shared {
		t.Fatal("precondition: the shared gate stays in the index, unforwarded, for p2")
	}
	if !gateHasBreakerWindow(reg, "serial:SER-REBIND") || gateHasBreakerWindow(reg, "sekey:PK-REBIND") {
		t.Fatal("precondition: the fault history moved to the enriched identity")
	}

	hold := reg.lockGate(ref1, "test")
	if hold.g != target {
		hold.unlock()
		t.Fatalf("p1's recorder locked %q, want the session's new gate serial:SER-REBIND", hold.g.key)
	}
	hold.g.breakerTrips++
	hold.g.updatedLocked(time.Now())
	hold.unlock()
	if got := providerBreakerTripsOf(reg, p1.id); got != 1 {
		t.Fatalf("p1's outcome did not land on its identity: trips=%d", got)
	}
	readGateForKey(reg, "sekey:PK-REBIND", func(g *gateState) {
		if g == nil || g.breakerTrips != 0 || g.outcomes != nil {
			t.Fatalf("p2's identity must be untouched by p1's stale recorder: %+v", g)
		}
	})

	hold = reg.lockGate(ref2, "test")
	if hold.g != shared {
		hold.unlock()
		t.Fatalf("p2's recorder locked %q, want its own (shared) gate", hold.g.key)
	}
	hold.g.healthWindowLocked().record(false, time.Now())
	hold.g.updatedLocked(time.Now())
	hold.unlock()
	if !gateHasBreakerWindow(reg, "sekey:PK-REBIND") || providerBreakerTripsOf(reg, p2.id) != 0 {
		t.Fatal("p2's outcome must land on p2's identity, and only there")
	}
}

// A trailing-flush recorder that resolved a disconnected identity's gate just
// before the sweep dropped it (idle, no live session, past the grace) must not
// write into the retired gate — the fault would vanish before the identity's
// next reconnect. lockGate sees retired, re-resolves, and the fault lands on
// the gate a fresh lookup finds. Both resolution paths: by session id through
// the disconnect cache (RecordProviderOutcome) and by stable id
// (RecordProviderServeOutcome).
func TestStaleRefSurvivesSweepOfDisconnectedGate(t *testing.T) {
	const key = "serial:SER-SWEEP-RACE"
	backdate := func(g *gateState) { g.touched = time.Now().Add(-gateIdleGrace - time.Minute) }
	for _, tc := range []struct {
		name    string
		resolve func(reg *testManager, sessionID string) gateRef[string]
	}{
		{"by session through the disconnect cache", func(reg *testManager, sessionID string) gateRef[string] { return reg.gateForSession(sessionID) }},
		{"by stable id", func(reg *testManager, _ string) gateRef[string] { return reg.gateForKey(key) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := newTestManager(testLogger())
			p := attachTestIdentity(reg, "sess-sweep-race", "serial:"+"SER-SWEEP-RACE")
			detachTestSession(reg, p.id)
			// Nothing was ever recorded on the identity, so its gate is idle;
			// backdate its creation past the grace so a PRESENT-time sweep
			// drops it (a future-time sweep would also expire the disconnect
			// cache the trailing flush resolves through).
			withGateForKey(reg, key, backdate)

			ref := tc.resolve(reg, p.id)
			stale := ref.g
			if stale == nil || stale.key != key || ref.p != nil {
				t.Fatalf("pre-sweep ref = %+v, want the disconnected identity's gate with no live session", ref)
			}
			reg.sweepGates(time.Now())
			if rawGateForKey(reg, key) != nil {
				t.Fatal("precondition: the sweep must drop the idle disconnected gate")
			}

			hold := reg.lockGate(ref, "test")
			if hold.g == stale {
				hold.unlock()
				t.Fatal("lockGate handed out the gate the sweep retired")
			}
			if hold.g.key != key || rawGateForKey(reg, key) != hold.g {
				hold.unlock()
				t.Fatalf("re-resolved to %q (in index: %v), want a fresh %s gate", hold.g.key, rawGateForKey(reg, key) == hold.g, key)
			}
			now := time.Now()
			hold.g.healthWindowLocked().record(false, now)
			hold.g.updatedLocked(now)
			hold.unlock()

			stale.mu.Lock()
			retired := stale.retired
			stale.mu.Unlock()
			if !retired {
				t.Fatal("the swept gate must be marked retired under its lock")
			}
			if !gateHasBreakerWindow(reg, key) {
				t.Fatal("the trailing fault must be on the gate a fresh lookup finds")
			}
			// The rest of the flush lands on the same gate and trips the
			// identity's breaker — the reconnecting-zombie signal survives.
			for i := 1; i < providerBreakerConsecTrip; i++ {
				reg.RecordProviderOutcome(p.id, false, 502, "provider disconnected")
			}
			if !reg.ProviderBreakerOpen(p.id) {
				t.Fatal("the identity's breaker must be open through the disconnected session id")
			}
		})
	}
}

// A CLEAR recorder (no-insert resolution) whose gate was swept in the window
// has nothing left to clear: it returns a nil hold rather than retaining the
// old gate or filing a gate under an identity nothing references.
func TestClearRefNeverFilesAGateForASweptIdentity(t *testing.T) {
	const key = "serial:SER-CLEAR-RACE"
	reg := newTestManager(testLogger())
	p := attachTestIdentity(reg, "sess-clear-race", "serial:"+"SER-CLEAR-RACE")
	detachTestSession(reg, p.id)
	withGateForKey(reg, key, func(g *gateState) { g.touched = time.Now().Add(-gateIdleGrace - time.Minute) })

	ref := reg.lookupSessionGateRef(p.id)
	stale := ref.g
	if stale == nil || stale.key != key || ref.insert {
		t.Fatalf("pre-sweep lookup ref = %+v, want a no-insert ref to the identity's gate", ref)
	}
	reg.sweepGates(time.Now())
	if rawGateForKey(reg, key) != nil {
		t.Fatal("precondition: the sweep must drop the idle disconnected gate")
	}
	hold := reg.lockGate(ref, "test")
	if hold.g != nil {
		hold.unlock()
		t.Fatalf("a clear re-resolved to %q; it must return a no-op hold", hold.g.key)
	}
	hold.unlock()
	if rawGateForKey(reg, key) != nil || rawGateForKey(reg, p.id) != nil {
		t.Fatal("a clear must not file a gate for a swept identity or a dead session")
	}
	// Through the real recorder, on the dead session: still nothing filed.
	reg.ClearDispatchLoadCooldown(p.id, "m")
	reg.RecordInferenceSuccess(p.id, "m", "base")
	if reg.gateCount() != 0 {
		t.Fatalf("gate index after a straggling clear = %d, want 0", reg.gateCount())
	}
}

// The lock-free "no per-model state" fast path the clear recorders and the
// probe claim take before locking must not trust the flag of a gate the
// session has moved away from: after a shared-identity rebind the emptied
// source says "nothing" precisely because the state migrated. refHasPairState
// re-resolves to the session's new gate; a genuinely empty current gate is
// reported as such without a re-resolve.
func TestRefHasPairStateFollowsSharedIdentityRebind(t *testing.T) {
	reg := newTestManager(testLogger())
	const model = "m"
	p1 := attachTestSession(reg, "sess-flag-rebind-1")
	p2 := attachTestSession(reg, "sess-flag-rebind-2")
	pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-FLAG-REBIND"}
	bindTestIdentity(reg, p1, pk)
	bindTestIdentity(reg, p2, pk)
	shared := reg.lookupGateForKey("sekey:PK-FLAG-REBIND")
	reg.RecordDispatchLoadFailure(p1.id, model)

	ref := reg.lookupSessionGateRef(p1.id) // ClearDispatchLoadCooldown's resolution
	if ref.g != shared || ref.p != p1 || !shared.hasPairState(gateFlagDispatchLoad) {
		t.Fatalf("pre-rebind ref = %+v, want the shared gate (with dispatch-load state) via p1", ref)
	}
	bindTestIdentity(reg, p1, &attestation.VerificationResult{Valid: true, PublicKey: "PK-FLAG-REBIND", SerialNumber: "SER-FLAG-REBIND"})
	target := p1.gate.Load()
	if target == shared || shared.hasPairState(gateFlagDispatchLoad) || !target.hasPairState(gateFlagDispatchLoad) {
		t.Fatal("precondition: the dispatch-load cooldown moved with the session and the shared gate reads empty")
	}

	got, has := reg.refHasPairState(ref, gateFlagDispatchLoad)
	if !has || got.g != target || got.p != p1 {
		t.Fatalf("refHasPairState = (%+v, %v), want the session's new gate with state", got, has)
	}
	// Through the real recorder: the completion-time clear lands on the new
	// identity, so the pair is routable again.
	reg.ClearDispatchLoadCooldown(p1.id, model)
	if reg.dispatchLoadCooled(p1.id, model, time.Now()) {
		t.Fatal("the clear must land on the session's new gate")
	}
	// A genuinely empty current gate: reported empty, ref unchanged.
	got, has = reg.refHasPairState(reg.lookupSessionGateRef(p2.id), gateFlagDispatchLoad)
	if has || got.g != shared {
		t.Fatalf("refHasPairState on p2's empty gate = (%+v, %v), want (shared, false)", got, has)
	}
}
