package registry

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
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
func TestGateRecordersRaceRebindsAndSweeps(t *testing.T) {
	reg := New(testLogger())
	const model = "m"
	p1 := makeSchedulerProvider(t, reg, "sess-stress-1", model, 100)
	p2 := makeSchedulerProvider(t, reg, "sess-stress-2", model, 100)
	pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-STRESS"}
	enriched := &attestation.VerificationResult{Valid: true, PublicKey: "PK-STRESS", SerialNumber: "SER-STRESS"}
	p1.SetAttestationResult(pk)
	p2.SetAttestationResult(pk)
	// A disconnected identity that keeps faulting (never idle) and one that
	// only ever sees successes (always idle: retired and re-created on every
	// sweep once backdated).
	gone := attestSchedulerProvider(t, reg, "sess-stress-gone", model, "SER-STRESS-GONE", 100)
	quiet := attestSchedulerProvider(t, reg, "sess-stress-quiet", model, "SER-STRESS-QUIET", 100)
	reg.Disconnect(gone.ID)
	reg.Disconnect(quiet.ID)
	// A second shared identity whose dispatch-load cooldown is armed once and
	// never cleared (nothing in the mix below touches it): cooled flaps between
	// the shared gate and its own serial while readers evaluate its routing
	// gate. Its sibling keeps the shared gate live.
	cooled := makeSchedulerProvider(t, reg, "sess-stress-cooled", model, 100)
	sibling := makeSchedulerProvider(t, reg, "sess-stress-cooled-sibling", model, 100)
	cooledPK := &attestation.VerificationResult{Valid: true, PublicKey: "PK-COOLED"}
	cooledEnriched := &attestation.VerificationResult{Valid: true, PublicKey: "PK-COOLED", SerialNumber: "SER-COOLED"}
	cooled.SetAttestationResult(cooledPK)
	sibling.SetAttestationResult(cooledPK)
	reg.RecordDispatchLoadFailure(cooled.ID, model)
	if !reg.dispatchLoadCooled(cooled.ID, model, time.Now()) {
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
		func(i int) { reg.RecordProviderOutcome(p1.ID, i%3 != 0, 500, "internal error") },
		func(i int) { reg.RecordCapacityReject(p1.ID, model) },
		func(i int) { reg.RecordCapacityAccept(p1.ID, model) },
		func(i int) { reg.RecordInferenceError(p1.ID, model, 500, "base") },
		func(i int) { reg.RecordInferenceSuccess(p1.ID, model, "base") },
		func(i int) { reg.ClearDispatchLoadCooldown(p1.ID, model) },
		func(i int) { reg.tryClaimCapacityProbe(p1, model, time.Now()) },
		func(i int) { reg.RecordProviderServeOutcome("sekey:PK-STRESS", i%2 == 0, 500, "internal error") },
		func(i int) { reg.RecordProviderOutcome(p2.ID, true, 200, "") },
		func(i int) { reg.RecordProviderOutcome(gone.ID, false, 502, "provider disconnected") },
		func(i int) { reg.RecordInferenceSuccess(quiet.ID, model, "base") },
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
				p1.SetAttestationResult(enriched)
			} else {
				p1.SetAttestationResult(pk)
			}
		}
	}()
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < iters; i++ {
			if i%2 == 0 {
				cooled.SetAttestationResult(cooledEnriched)
			} else {
				cooled.SetAttestationResult(cooledPK)
			}
		}
	}()
	// Routing readers: the scan's gate evaluation for cooled, as the scan runs
	// it (view loaded, then read under p.mu). admitted counts verdicts that let
	// the cooled pair through; bounded counts evaluations that hit the re-read
	// bound (documented fallback to the last view — not a verdict this test
	// judges).
	var admitted, bounded atomic.Int32
	for reader := 0; reader < 2; reader++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				view := reg.gateViewOf(cooled)
				cooled.mu.Lock()
				ok, reason := reg.gateStateReasonLocked(&view, model, RequestTraits{}, time.Now(), false, false)
				cooled.mu.Unlock()
				if view.rereads >= gateRelockMaxRetries {
					bounded.Add(1)
					continue
				}
				if ok || reason != GateDispatchLoadCooldown {
					admitted.Add(1)
				}
			}
		}()
	}
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
	if n := admitted.Load(); n != 0 {
		t.Fatalf("%d routing reads admitted the cooled session mid-rebind (want 0; %d hit the re-read bound)", n, bounded.Load())
	}
	if n := bounded.Load(); n != 0 {
		t.Logf("%d routing reads hit the re-read bound", n)
	}
	if g := sibling.gate.Load(); g == nil || g.key != "sekey:PK-COOLED" || rawGateForKey(reg, "sekey:PK-COOLED") != g {
		t.Fatalf("the cooled sibling's binding was disturbed: %+v", g)
	}
	if !reg.dispatchLoadCooled(cooled.ID, model, time.Now()) {
		t.Fatal("the cooled session's pair must still read cooled through its current identity")
	}
	p1.SetAttestationResult(enriched)
	reg.RecordProviderOutcome(p1.ID, false, 500, "internal error")
	readGateForSession(reg, p1.ID, func(g *gateState) {
		if g == nil || g.key != "serial:SER-STRESS" || g.outcomes == nil {
			t.Fatalf("a quiescent fault must land on p1's current gate: %+v", g)
		}
	})
}
