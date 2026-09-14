package faultstate

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"testing"
	"time"
)

// A recorder that resolved the session's gate just before attestation bound
// the stable identity must land its outcome on the identity's gate, not on
// the orphaned session gate: lockGate follows the forward set by the
// migration, and the orphan is gone from the index.
func TestStaleGatePointerFollowsIdentityMigration(t *testing.T) {
	reg := newTestManager(testLogger())
	p := attachTestSession(reg, "sess-stale")
	ref := reg.gateForSession(p.id)
	stale := ref.g
	if stale == nil || stale.key != p.id {
		t.Fatalf("pre-bind gate = %+v, want the session-keyed gate", stale)
	}

	bindTestIdentity(reg, p, &attestation.VerificationResult{Valid: true, SerialNumber: "SER-STALE"})
	target := reg.lookupGateForKey("serial:SER-STALE")
	if target == nil || target.key != "serial:SER-STALE" {
		t.Fatalf("bind did not file the identity's gate: %+v", target)
	}
	if rawGateForKey(reg, p.id) != nil {
		t.Fatal("the orphaned session gate must leave the index")
	}
	if stale.resolve() != target {
		t.Fatal("resolve() on the stale pointer must follow the migration forward")
	}
	hold := reg.lockGate(ref, "test")
	if hold.g != target {
		hold.unlock()
		t.Fatal("lockGate on the stale pointer must lock the live gate")
	}
	hold.g.breakerTrips++
	hold.g.updatedLocked(time.Now())
	hold.unlock()
	if got := providerBreakerTripsOf(reg, p.id); got != 1 {
		t.Fatalf("mutation through the stale pointer landed elsewhere: trips=%d", got)
	}
	if p.gate.Load() != target {
		t.Fatal("the provider's cached gate must point at the identity's gate")
	}
}

// During a live re-attestation that changes the identity, a lock-free reader
// must never see the identity's fault state vanish: the orphaned session gate
// keeps its (conservative) atomics — it is never republished after the reset
// — and the provider's cached pointer is repointed only once the target
// carries the merged state.
func TestMigrationNeverExposesAnEmptyGateToLockFreeReaders(t *testing.T) {
	reg := newTestManager(testLogger())
	p := attachTestSession(reg, "sess-mig-view")
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.id, false, 500, "internal error")
	}
	stale := p.gate.Load()
	nowNS := time.Now().UnixNano()
	if !stale.breakerOpenAt(nowNS) {
		t.Fatal("precondition: breaker open on the session gate")
	}

	bindTestIdentity(reg, p, &attestation.VerificationResult{Valid: true, SerialNumber: "SER-MIG-VIEW"})

	target := p.gate.Load()
	if target == stale || target.key != "serial:SER-MIG-VIEW" {
		t.Fatalf("cached gate after bind = %+v, want the identity's gate", target)
	}
	if !target.breakerOpenAt(nowNS) {
		t.Fatal("the target must carry the merged breaker state when the pointer is repointed")
	}
	if !stale.breakerOpenAt(nowNS) {
		t.Fatal("the orphaned gate's atomics must stay conservative (never republished after the reset)")
	}
	if stale.forwardTo.Load() != target || !stale.resolve().breakerOpenAt(nowNS) {
		t.Fatal("the orphan must forward to the live gate")
	}
	if !reg.ProviderBreakerOpen(p.id) {
		t.Fatal("the breaker must read open through the session after the rebind")
	}
}

// A rebind that moves ONE of two sessions bound to the same identity must not
// orphan the shared gate: the other session still points at it, so it stays
// in the index (emptied, as the map-keyed implementation left the old key).
func TestRebindKeepsSharedIdentityGateForOtherSessions(t *testing.T) {
	reg := newTestManager(testLogger())
	p1 := attachTestSession(reg, "sess-shared-1")
	p2 := attachTestSession(reg, "sess-shared-2")
	bindTestIdentity(reg, p1, &attestation.VerificationResult{Valid: true, PublicKey: "PK-SHARED"})
	bindTestIdentity(reg, p2, &attestation.VerificationResult{Valid: true, PublicKey: "PK-SHARED"})
	shared := reg.lookupGateForKey("sekey:PK-SHARED")
	if shared == nil || p1.gate.Load() != shared || p2.gate.Load() != shared {
		t.Fatal("both sessions must share the identity's gate")
	}
	reg.RecordProviderOutcome(p1.id, false, 500, "internal error")

	// p1 enriches to a serial; p2 stays on the SE key.
	bindTestIdentity(reg, p1, &attestation.VerificationResult{Valid: true, PublicKey: "PK-SHARED", SerialNumber: "SER-ONE"})
	if rawGateForKey(reg, "sekey:PK-SHARED") != shared {
		t.Fatal("the shared gate must stay in the index while another session is bound to it")
	}
	if shared.forwardTo.Load() != nil {
		t.Fatal("a gate with a live session must not be forwarded")
	}
	if p2.gate.Load() != shared {
		t.Fatal("the other session's cached gate must be untouched")
	}
	if !gateHasBreakerWindow(reg, "serial:SER-ONE") {
		t.Fatal("the fault history must have moved to the enriched identity")
	}
	if gateHasBreakerWindow(reg, "sekey:PK-SHARED") {
		t.Fatal("the source identity must start from nothing after the migration")
	}
	reg.gatesMu.RLock()
	live := shared.live
	reg.gatesMu.RUnlock()
	if live != 1 {
		t.Fatalf("shared gate live sessions = %d, want 1", live)
	}
}
