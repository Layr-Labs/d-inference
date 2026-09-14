package registry

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Tests for the recorders' validated gate lock (gate_lock.go): the probe
// claim's per-identity exclusivity, the wait observer, recorders never
// blocking behind r.mu, and lockGate / refHasPairState re-resolving a gate
// that a shared-identity rebind or a sweep invalidated in the window between
// the index lookup and the lock. The trackers' semantics are covered by
// their own files; the commit lock mode lives in reserve_commit_test.go.

// Two sessions of one identity racing for the single half-open probe: the
// check-and-claim under gate.mu lets exactly one through, and the gate reads
// closed for both afterwards.
func TestTryClaimCapacityProbeIsExclusivePerIdentity(t *testing.T) {
	reg := newClockedFaultRegistry(t)
	const model = "m"
	p1 := attestSchedulerProvider(t, reg, "sess-probe-1", model, "SER-PROBE", 100)
	p2 := attestSchedulerProvider(t, reg, "sess-probe-2", model, "SER-PROBE", 100)
	if !reg.gateOf(p1).SameGate(reg.gateOf(p2)) {
		t.Fatal("sessions of one identity must share a gate")
	}
	for i := 0; i < reg.faults.Policy().CapacityCooldown.Threshold; i++ {
		reg.RecordCapacityReject(p1.ID, model)
	}
	if !reg.CapacityCooldownActive(p2.ID, model) {
		t.Fatal("the cooldown must be visible through the sibling session")
	}
	expireCapacityCooldown(reg, p1.ID, model)
	if reg.CapacityCooldownActive(p1.ID, model) {
		t.Fatal("an expired, unclaimed cooldown must read open")
	}

	now := time.Now()
	var claimed atomic.Int32
	var wg sync.WaitGroup
	for _, p := range []*Provider{p1, p2, p1, p2} {
		wg.Add(1)
		go func(p *Provider) {
			defer wg.Done()
			if reg.tryClaimCapacityProbe(p, model, now) {
				claimed.Add(1)
			}
		}(p)
	}
	wg.Wait()
	if claimed.Load() != 1 {
		t.Fatalf("probe claims = %d, want exactly 1", claimed.Load())
	}
	if !reg.CapacityCooldownActive(p1.ID, model) || !reg.CapacityCooldownActive(p2.ID, model) {
		t.Fatal("the claimed probe must close the gate for every session of the identity")
	}
	// No cooldown entry at all: the claim is a lock-free no-op that admits.
	if !reg.tryClaimCapacityProbe(p1, "other-model", now) {
		t.Fatal("a pair with no cooldown entry must always claim")
	}
}

// A gate.mu wait above the threshold reaches the observer tagged by site — and
// only then: uncontended recorders report nothing.
func TestGateWaitObserverReportsLongWaits(t *testing.T) {
	reg := New(testLogger())
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

	release := reg.HoldGateForTest(p.ID)
	go func() {
		time.Sleep(20 * time.Millisecond)
		release()
	}()
	reg.RecordProviderOutcome(p.ID, true, 200, "")
	mu.Lock()
	defer mu.Unlock()
	if len(got) != 1 || got[0].site != "breaker" || got[0].wait < 5*time.Millisecond {
		t.Fatalf("observer calls = %+v, want one 'breaker' wait of >= 5ms", got)
	}
	reg.SetGateWaitObserver(nil)
}

// An accept on the first-byte path must not queue behind the registry write
// lock: with r.mu held for writing by someone else, the recorders still run.
func TestRecordersDoNotTakeTheRegistryWriteLock(t *testing.T) {
	reg := New(testLogger())
	p := attestSchedulerProvider(t, reg, "sess-nolock", "m", "SER-NOLOCK", 100)
	reg.mu.Lock()
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
		reg.mu.Unlock()
		t.Fatal("a recorder blocked behind the registry write lock")
	}
	reg.mu.Unlock()
}

// A reservation commit that resolved the probe's gate just before its session
// rebound away from a SHARED identity must claim the probe on the session's
// NEW gate — where the cooldown entry migrated — and leave the other
// identity's (reset) state untouched. A claim on the old gate would find no
// entry and admit: a leaked probe through a cooled pair. The claim is the
// same in both commit modes (the mode only chooses the r.mu lock kind).
func TestProbeClaimFollowsSharedIdentityRebind(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		reg := newClockedFaultRegistry(t)
		setReserveCommitModeForTest(reg, mode)
		const model = "m"
		p1 := makeSchedulerProvider(t, reg, "sess-probe-rebind-1", model, 100)
		p2 := makeSchedulerProvider(t, reg, "sess-probe-rebind-2", model, 100)
		pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-PROBE-REBIND"}
		p1.SetAttestationResult(pk)
		p2.SetAttestationResult(pk)
		shared := reg.faults.ViewForKey("sekey:PK-PROBE-REBIND")
		if !shared.Present() || !reg.gateOf(p1).SameGate(shared) || !reg.gateOf(p2).SameGate(shared) {
			t.Fatal("both sessions must share the identity's gate")
		}
		for i := 0; i < reg.faults.Policy().CapacityCooldown.Threshold; i++ {
			reg.RecordCapacityReject(p1.ID, model)
		}
		expireCapacityCooldown(reg, p1.ID, model)
		if reg.CapacityCooldownActive(p1.ID, model) {
			t.Fatal("precondition: an expired, unclaimed cooldown must read open")
		}

		// The commit resolves the probe's gate (under p.mu)...
		ref := reg.probeGateRef(p1)
		if !ref.g.SameGate(shared) || ref.p != p1 {
			t.Fatalf("probe ref = %+v, want the shared gate via p1", ref)
		}
		// ...and p1 enriches to a serial before the claim takes the lock.
		p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-PROBE-REBIND", SerialNumber: "SER-PROBE-REBIND"})
		target := reg.gateOf(p1)
		if target.SameGate(shared) || target.Key() != "serial:SER-PROBE-REBIND" {
			t.Fatalf("p1's gate after the rebind = %+v, want serial:SER-PROBE-REBIND", target)
		}
		if !target.HasCapacityCooldown() || shared.HasCapacityCooldown() {
			t.Fatal("precondition: the cooldown entry moved with the session")
		}

		now := time.Now()
		if !reg.claimCapacityProbeRef(ref, model, now) {
			t.Fatal("the expired, unclaimed probe must be claimable")
		}
		claimed := reg.faults.StatusForKey("serial:SER-PROBE-REBIND", model, "")
		if !claimed.Found {
			t.Fatal("the enriched identity's gate must exist")
		}
		if !claimed.CapacityPresent || !claimed.CapacityProbeAt.Equal(now) {
			t.Fatalf("the claim must land on the session's new gate: entry=%+v", claimed)
		}
		unchanged := reg.faults.StatusForKey("sekey:PK-PROBE-REBIND", model, "")
		if !unchanged.Found {
			t.Fatal("the shared gate must stay in the index for p2")
		}
		if unchanged.CapacityCooldownKeys != 0 {
			t.Fatalf("the other identity's state must be untouched by the stale claim: %+v", unchanged)
		}
		if !reg.CapacityCooldownActive(p1.ID, model) {
			t.Fatal("the claimed probe must close the gate for p1's identity")
		}
		if reg.CapacityCooldownActive(p2.ID, model) {
			t.Fatal("p2's identity carries no cooldown after the migration")
		}
		// A second commit through the live path sees the fresh claim: exactly
		// one probe gets through.
		if reg.tryClaimCapacityProbe(p1, model, now) {
			t.Fatal("a second claim must see the fresh claim and reject")
		}
	})
}
