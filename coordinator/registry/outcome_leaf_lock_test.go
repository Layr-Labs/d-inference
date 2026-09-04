package registry

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Registry.outcomeMu: the three always-write success recorders
// (RecordProviderOutcome(ok), RecordProviderServeOutcome(ok) and the rate-on
// RecordCapacityAcceptOutcome) leave Registry.mu. These tests pin the lock
// scope, the served-path write-acquisition count, identical verdicts, the
// arrival-order semantics, identity migration across the leaf lock, and the
// -race storm.

// TestSuccessRecordersLeaveRegistryMu: with a reservation scan parked under
// r.mu.RLock, each success recorder returns while the scan is parked and no
// writer is queued on Registry.mu. Before the leaf lock each blocked on
// r.mu.Lock until the scan released.
func TestSuccessRecordersLeaveRegistryMu(t *testing.T) {
	reg := New(testLogger())
	model := "leaf-scope-model"
	p := planTestProvider(t, reg, "leaf-p", model, 0)
	if reg.capacityRateCfg.PenaltyMs <= 0 {
		t.Fatal("fixture: the capacity-503 rate tracker must be on (default) so the accept always writes")
	}

	parked := make(chan struct{})
	release := make(chan struct{})
	reg.reservationAfterScan = func(string) {
		close(parked)
		<-release
	}
	scanDone := make(chan struct{})
	go func() {
		defer close(scanDone)
		pr := planTestRequest("leaf-req", 100, 100)
		pr.Model = model
		if got, _ := reg.ReserveProviderEx(model, pr); got != nil {
			got.RemovePending(pr.RequestID)
		}
	}()
	<-parked

	recorders := []struct {
		name string
		call func()
	}{
		{"RecordCapacityAccept (rate on)", func() { reg.RecordCapacityAccept(p.ID, model) }},
		{"RecordCapacityAcceptOutcome(count=false)", func() { reg.RecordCapacityAcceptOutcome(p.ID, model, false) }},
		{"RecordProviderOutcome(ok)", func() { reg.RecordProviderOutcome(p.ID, true, 200, "") }},
		{"RecordProviderServeOutcome(ok)", func() { reg.RecordProviderServeOutcome("serial:leaf", true, 200, "") }},
		{"RecordProviderOutcome(healthy shed)", func() { reg.RecordProviderOutcome(p.ID, false, 503, "token_budget exhausted") }},
	}
	for _, rec := range recorders {
		done := make(chan struct{})
		go func() {
			defer close(done)
			rec.call()
		}()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			close(release)
			<-scanDone
			t.Fatalf("%s blocked behind the parked scan (queued as a writer)", rec.name)
		}
	}
	if w := reg.LockWaitPeek().WritersWaiting; w != 0 {
		t.Fatalf("writers waiting = %d while the scan is parked, want 0", w)
	}
	close(release)
	<-scanDone
}

// TestServedPathTakesOneWriteLock pins the structural property the lock work
// exists for: a whole served request — reserve, commit-time accept, release,
// and the five completion recorders — takes Registry.mu for writing exactly
// once (the reservation commit). It was six.
func TestServedPathTakesOneWriteLock(t *testing.T) {
	reg := New(testLogger())
	model := "leaf-one-lock-model"
	p := planTestProvider(t, reg, "one-lock", model, 0)
	pr := planTestRequest("one-lock-req", 100, 100)
	pr.Model = model
	before := reg.LockWaitPeek().Count
	got, decision := reg.ReserveProviderEx(model, pr)
	if got == nil {
		t.Fatalf("reservation failed: %+v", decision)
	}
	if reg.RecordCapacityAccept(p.ID, model) {
		pr.MarkRateOutcomeCounted()
	}
	got.RemovePending(pr.RequestID)
	reg.RecordInferenceSuccess(p.ID, model, "base")
	reg.RecordCapacityAcceptOutcome(p.ID, model, !pr.RateOutcomeCountedSafe())
	reg.RecordProviderOutcome(p.ID, true, 200, "")
	reg.RecordProviderServeOutcome("serial:one-lock", true, 200, "")
	reg.ClearDispatchLoadCooldown(p.ID, model)
	if n := reg.LockWaitPeek().Count - before; n != 1 {
		t.Fatalf("served path took %d exclusive Registry.mu acquisitions, want 1 (the commit)", n)
	}
}

// TestLeafLockPreservesBreakerAndEjectionVerdicts: trip, half-open re-arm and
// success-close are byte-identical to the single-lock implementation, and
// every transition is reported exactly once.
func TestLeafLockPreservesBreakerAndEjectionVerdicts(t *testing.T) {
	reg := New(testLogger())
	const id = "verdict-node"
	for i := 0; i < providerBreakerConsecTrip-1; i++ {
		if opened, _ := reg.RecordProviderOutcome(id, false, 500, "boom"); opened {
			t.Fatalf("fault %d tripped early", i+1)
		}
	}
	// A success mid-streak resets the consecutive count — the next fault
	// cannot trip on the consecutive condition.
	if _, closed := reg.RecordProviderOutcome(id, true, 200, ""); closed {
		t.Fatal("success on a closed breaker reported a close")
	}
	if opened, _ := reg.RecordProviderOutcome(id, false, 500, "boom"); opened {
		t.Fatal("consecutive count must reset on success")
	}
	for i := 0; i < providerBreakerConsecTrip-1; i++ {
		reg.RecordProviderOutcome(id, false, 500, "boom")
	}
	if !reg.ProviderBreakerOpen(id) {
		t.Fatal("breaker should be open after the consecutive-fault streak")
	}
	// Success closes it exactly once.
	if _, closed := reg.RecordProviderOutcome(id, true, 200, ""); !closed {
		t.Fatal("success must close the open breaker")
	}
	if _, closed := reg.RecordProviderOutcome(id, true, 200, ""); closed {
		t.Fatal("second success reported a second close")
	}
	if reg.ProviderBreakerOpen(id) {
		t.Fatal("breaker still open after the success")
	}

	// Ejection: capacity streak trips, accept recovers, trips are cleared.
	const sid = "serial:verdict"
	for i := 0; i < healthEjectionCapacityConsecTrip-1; i++ {
		if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, "token_budget exhausted"); ejected {
			t.Fatalf("capacity strike %d ejected early", i+1)
		}
	}
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, "token_budget exhausted"); !ejected {
		t.Fatal("capacity streak must eject at the threshold")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("identity should be ejected")
	}
	if _, recovered := reg.RecordProviderServeOutcome(sid, true, 200, ""); !recovered {
		t.Fatal("success must recover the ejected identity")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("identity still ejected after recovery")
	}
	reg.mu.RLock()
	reg.outcomeMu.RLock()
	_, trips := reg.healthEjectionTrips[sid]
	_, streak := reg.healthEjectionCapacityStreaks[sid]
	reg.outcomeMu.RUnlock()
	reg.mu.RUnlock()
	if trips || streak {
		t.Fatalf("recovery must clear trips (%v) and the capacity streak (%v)", trips, streak)
	}
}

// TestSuccessDoesNotCloseBreakerTrippedAfterIt pins the arrival-order rule
// the leaf lock serializes on: a success serialized BEFORE a trip must not
// close that trip (the trip already saw it in the ring), while a success
// serialized AFTER the trip closes it. Both orders run through the real
// recorders.
func TestSuccessDoesNotCloseBreakerTrippedAfterIt(t *testing.T) {
	trip := func(reg *Registry, id string) {
		for i := 0; i < providerBreakerConsecTrip; i++ {
			reg.RecordProviderOutcome(id, false, 500, "boom")
		}
	}
	t.Run("success then trip stays open", func(t *testing.T) {
		reg := New(testLogger())
		reg.RecordProviderOutcome("n", true, 200, "")
		trip(reg, "n")
		if !reg.ProviderBreakerOpen("n") {
			t.Fatal("a trip serialized after the success must stay open")
		}
	})
	t.Run("trip then success closes", func(t *testing.T) {
		reg := New(testLogger())
		trip(reg, "n")
		if _, closed := reg.RecordProviderOutcome("n", true, 200, ""); !closed || reg.ProviderBreakerOpen("n") {
			t.Fatal("a success serialized after the trip must close it")
		}
	})
}

// TestMigrateFaultStateMovesLeafLockedWindows: a consecutive-fault streak
// recorded under the session key survives the identity rebind (the ring is
// moved under outcomeMu) — the fifth fault under the stable key trips.
func TestMigrateFaultStateMovesLeafLockedWindows(t *testing.T) {
	reg := New(testLogger())
	model := "leaf-migrate-model"
	p := makeSchedulerProvider(t, reg, "sess-migrate", model, 100)
	for i := 0; i < providerBreakerConsecTrip-1; i++ {
		reg.RecordProviderOutcome(p.ID, false, 500, "boom")
	}
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "MIG-LEAF"})
	reg.mu.RLock()
	reg.outcomeMu.RLock()
	_, moved := reg.providerOutcomes["serial:MIG-LEAF"]
	_, orphan := reg.providerOutcomes[p.ID]
	reg.outcomeMu.RUnlock()
	reg.mu.RUnlock()
	if !moved || orphan {
		t.Fatalf("ring moved=%v orphan=%v, want the window under the stable key only", moved, orphan)
	}
	if opened, _ := reg.RecordProviderOutcome(p.ID, false, 500, "boom"); !opened {
		t.Fatal("the streak must continue under the migrated key and trip on the fifth fault")
	}
	if !reg.ProviderBreakerOpen(p.ID) {
		t.Fatal("breaker should be open via the stable key")
	}
	// Trip -> Disconnect -> re-register under the same serial: still open,
	// the leaf-locked ring included.
	reg.Disconnect(p.ID)
	p2 := makeSchedulerProvider(t, reg, "sess-migrate-2", model, 100)
	p2.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "MIG-LEAF"})
	if !reg.ProviderBreakerOpen(p2.ID) {
		t.Fatal("breaker state must survive reconnect under the stable key")
	}
	if _, closed := reg.RecordProviderOutcome(p2.ID, true, 200, ""); !closed {
		t.Fatal("success on the reconnected session must close the breaker via the stable key")
	}
}

// TestCapacityRatePenaltyReadsLeafLockedAccepts: the penalty computed from
// the leaf-locked accept window equals the formula over both windows on the
// 350x2 bench fleet (20% of pairs cooled), and healthy pairs pay nothing.
func TestCapacityRatePenaltyReadsLeafLockedAccepts(t *testing.T) {
	reg := buildReserveBenchFleet(t)
	now := time.Now()
	checked, penalized := 0, 0
	for i := 0; i < reserveBenchProviders; i++ {
		id := fmt.Sprintf("bench-%04d", i)
		// Give every pair some accepts so the denominator is non-trivial.
		for k := 0; k < 4; k++ {
			reg.RecordCapacityAcceptOutcome(id, reserveBenchModelA, true)
		}
		reg.mu.RLock()
		key := capacityRejectKey{ProviderID: reg.faultKeyLocked(id), ModelID: reserveBenchModelA}
		rejects := countInWindow(reg.capacityRateRejects[key], now)
		reg.outcomeMu.RLock()
		accepts := countInWindow(reg.capacityRateAccepts[key], now)
		reg.outcomeMu.RUnlock()
		got, rate := reg.capacityRatePenaltyLocked(id, reserveBenchModelA, now)
		reg.mu.RUnlock()
		var want float64
		if rejects > 0 {
			r := float64(rejects) / float64(rejects+accepts)
			if rejects+accepts >= capacityRateMinSample && r > capacityRateThreshold {
				want = r * reg.capacityRateCfg.PenaltyMs
			}
			if rate != r {
				t.Fatalf("%s: rate=%v want %v", id, rate, r)
			}
			penalized++
		}
		if got != want {
			t.Fatalf("%s: penalty=%v want %v (rejects %d accepts %d)", id, got, want, rejects, accepts)
		}
		checked++
	}
	if checked != reserveBenchProviders || penalized == 0 {
		t.Fatalf("checked %d pairs, %d with rejects; want all %d and some cooled", checked, penalized, reserveBenchProviders)
	}
}

// TestOutcomeRecorderStormUnderRace: 100 goroutines of faults / capacity
// rejects / inference errors interleaved with 100 goroutines of successes
// while a reader is parked; run with -race. Invariant: every breaker and
// ejection transition is reported exactly once and the final open state
// equals the transition ledger (opens − closes ∈ {0, 1}).
func TestOutcomeRecorderStormUnderRace(t *testing.T) {
	reg := New(testLogger())
	model := "leaf-storm-model"
	const nodes = 8
	ids := make([]string, nodes)
	for i := range ids {
		ids[i] = fmt.Sprintf("storm-%d", i)
		makeSchedulerProvider(t, reg, ids[i], model, 100)
	}
	reg.mu.RLock() // a parked reader batch, as in production
	var opened, closed, ejected, recovered [nodes]atomic.Int64
	var wg sync.WaitGroup
	for g := 0; g < 100; g++ {
		wg.Add(2)
		go func(g int) {
			defer wg.Done()
			for k := 0; k < 20; k++ {
				i := (g + k) % nodes
				switch k % 3 {
				case 0:
					if o, c := reg.RecordProviderOutcome(ids[i], false, 500, "boom"); o {
						opened[i].Add(1)
					} else if c {
						closed[i].Add(1)
					}
				case 1:
					if e, r := reg.RecordProviderServeOutcome("serial:"+ids[i], false, 503, "token_budget exhausted"); e {
						ejected[i].Add(1)
					} else if r {
						recovered[i].Add(1)
					}
				default:
					reg.RecordCapacityReject(ids[i], model)
					reg.RecordInferenceError(ids[i], model, 500, "base")
				}
			}
		}(g)
		go func(g int) {
			defer wg.Done()
			for k := 0; k < 20; k++ {
				i := (g*7 + k) % nodes
				if _, c := reg.RecordProviderOutcome(ids[i], true, 200, ""); c {
					closed[i].Add(1)
				}
				if _, r := reg.RecordProviderServeOutcome("serial:"+ids[i], true, 200, ""); r {
					recovered[i].Add(1)
				}
				reg.RecordCapacityAcceptOutcome(ids[i], model, k%2 == 0)
				reg.RecordInferenceSuccess(ids[i], model, "base")
			}
		}(g)
	}
	// Release the reader after the writers have had time to queue.
	time.Sleep(20 * time.Millisecond)
	reg.mu.RUnlock()
	wg.Wait()
	for i, id := range ids {
		if d := opened[i].Load() - closed[i].Load(); d < 0 || d > 1 || (d == 1) != reg.ProviderBreakerOpen(id) {
			t.Fatalf("%s: breaker opens=%d closes=%d open=%v — transitions must balance the final state", id, opened[i].Load(), closed[i].Load(), reg.ProviderBreakerOpen(id))
		}
		sid := "serial:" + id
		if d := ejected[i].Load() - recovered[i].Load(); d < 0 || d > 1 || (d == 1) != reg.HealthEjectionOpen(sid) {
			t.Fatalf("%s: ejections=%d recoveries=%d open=%v — transitions must balance the final state", sid, ejected[i].Load(), recovered[i].Load(), reg.HealthEjectionOpen(sid))
		}
	}
}
