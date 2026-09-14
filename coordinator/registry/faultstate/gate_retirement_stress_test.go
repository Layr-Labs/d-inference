package faultstate

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"sync"
	"testing"
	"time"
)

// Recorders and routing reads racing identity rebinds (shared ↔ enriched) and
// sweeps that keep retiring idle gates: interleaving coverage under -race for
// lockGate's re-validation and gateView's confirmation. The deterministic
// tests (gate_lock_test.go, gate_index_test.go) carry the outcome assertions;
// here the invariants are "no retired gate is ever in the index", "the other
// session's binding is never disturbed", a quiescent record lands on the
// session's current gate — and, for a session that flaps between a shared
// and an enriched identity while carrying a dispatch-load cooldown, the
// routing read NEVER admits it: the cooldown follows the session through
// every rebind (mergeLocked keeps the max expiry both ways), so a "not
// gated" verdict could only come from trusting the emptied shared source.
func TestGateRecordersRaceOwnerRetirement(t *testing.T) {
	reg := newTestManager(testLogger())
	const model = "m"
	p1 := attachTestSession(reg, "sess-stress-1")
	p2 := attachTestSession(reg, "sess-stress-2")
	pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-STRESS"}
	enriched := &attestation.VerificationResult{Valid: true, PublicKey: "PK-STRESS", SerialNumber: "SER-STRESS"}
	bindTestIdentity(reg, p1, pk)
	bindTestIdentity(reg, p2, pk)
	// A disconnected identity that keeps faulting (never idle) and one that
	// only ever sees successes (always idle: retired and re-created on every
	// sweep once backdated).
	gone := attachTestIdentity(reg, "sess-stress-gone", "serial:"+"SER-STRESS-GONE")
	quiet := attachTestIdentity(reg, "sess-stress-quiet", "serial:"+"SER-STRESS-QUIET")
	detachTestSession(reg, gone.id)
	detachTestSession(reg, quiet.id)
	// A second shared identity whose dispatch-load cooldown is armed once and
	// never cleared (nothing in the mix below touches it): cooled flaps between
	// the shared gate and its own serial while readers evaluate its routing
	// gate. Its sibling keeps the shared gate live.
	cooled := attachTestSession(reg, "sess-stress-cooled")
	sibling := attachTestSession(reg, "sess-stress-cooled-sibling")
	cooledPK := &attestation.VerificationResult{Valid: true, PublicKey: "PK-COOLED"}
	cooledEnriched := &attestation.VerificationResult{Valid: true, PublicKey: "PK-COOLED", SerialNumber: "SER-COOLED"}
	bindTestIdentity(reg, cooled, cooledPK)
	bindTestIdentity(reg, sibling, cooledPK)
	reg.RecordDispatchLoadFailure(cooled.id, model)
	if !reg.dispatchLoadCooled(cooled.id, model, time.Now()) {
		t.Fatal("precondition: the cooled session's pair must be dispatch-load cooled")
	}

	backdateAll := func() {
		reg.gatesMu.RLock()
		gates := make([]*gateState, 0, len(reg.gates))
		for _, g := range reg.gates {
			gates = append(gates, g)
		}
		reg.gatesMu.RUnlock()
		past := time.Now().Add(-gateIdleGrace - time.Minute)
		for _, g := range gates {
			g.mu.Lock()
			g.touched = past
			g.mu.Unlock()
		}
	}

	const iters = 1500
	var wg sync.WaitGroup
	recorders := []func(i int){
		func(i int) { reg.RecordProviderOutcome(p1.id, i%3 != 0, 500, "internal error") },
		func(i int) { reg.RecordCapacityReject(p1.id, model) },
		func(i int) { reg.RecordCapacityAccept(p1.id, model) },
		func(i int) { reg.RecordInferenceError(p1.id, model, 500, "base") },
		func(i int) { reg.RecordInferenceSuccess(p1.id, model, "base") },
		func(i int) { reg.ClearDispatchLoadCooldown(p1.id, model) },
		func(i int) { reg.TryClaimCapacityProbe(p1, p1.id, model, time.Now()) },
		func(i int) { reg.RecordProviderServeOutcome("sekey:PK-STRESS", i%2 == 0, 500, "internal error") },
		func(i int) { reg.RecordProviderOutcome(p2.id, true, 200, "") },
		func(i int) { reg.RecordProviderOutcome(gone.id, false, 502, "provider disconnected") },
		func(i int) { reg.RecordInferenceSuccess(quiet.id, model, "base") },
		func(i int) { reg.RecordProviderServeOutcome("serial:SER-STRESS-QUIET", true, 200, "") },
	}
	for _, rec := range recorders {
		wg.Add(1)
		go func(rec func(int)) {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				rec(i)
			}
		}(rec)
	}
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iters; i++ {
			if i%2 == 0 {
				bindTestIdentity(reg, p1, enriched)
			} else {
				bindTestIdentity(reg, p1, pk)
			}
		}
	}()
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iters; i++ {
			if i%2 == 0 {
				bindTestIdentity(reg, cooled, cooledEnriched)
			} else {
				bindTestIdentity(reg, cooled, cooledPK)
			}
		}
	}()
	stop := make(chan struct{})
	sweeperDone := make(chan struct{})
	go func() {
		defer close(sweeperDone)
		for {
			select {
			case <-stop:
				return
			default:
			}
			backdateAll()
			reg.sweepGates(time.Now())
		}
	}()
	wg.Wait()
	close(stop)
	<-sweeperDone

	reg.gatesMu.RLock()
	for key, g := range reg.gates {
		g.mu.Lock()
		retired := g.retired
		g.mu.Unlock()
		if retired {
			t.Errorf("retired gate %q is still in the index", key)
		}
	}
	reg.gatesMu.RUnlock()
	if g := p2.gate.Load(); g == nil || g.key != "sekey:PK-STRESS" || rawGateForKey(reg, "sekey:PK-STRESS") != g {
		t.Fatalf("p2's binding was disturbed: %+v", g)
	}
	if g := sibling.gate.Load(); g == nil || g.key != "sekey:PK-COOLED" || rawGateForKey(reg, "sekey:PK-COOLED") != g {
		t.Fatalf("the cooled sibling's binding was disturbed: %+v", g)
	}
	if !reg.dispatchLoadCooled(cooled.id, model, time.Now()) {
		t.Fatal("the cooled session's pair must still read cooled through its current identity")
	}
	bindTestIdentity(reg, p1, enriched)
	reg.RecordProviderOutcome(p1.id, false, 500, "internal error")
	readGateForSession(reg, p1.id, func(g *gateState) {
		if g == nil || g.key != "serial:SER-STRESS" || g.outcomes == nil {
			t.Fatalf("a quiescent fault must land on p1's current gate: %+v", g)
		}
	})
}
