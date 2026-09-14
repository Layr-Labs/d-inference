package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestRejectedProviderClassificationFollowsSharedRebind(t *testing.T) {
	setHealthEjectionEnabledForTest(t, true)
	for _, tc := range []struct {
		name              string
		set               func(*Registry, string, time.Time)
		breaker, capacity bool
	}{
		{"breaker", func(r *Registry, id string, until time.Time) {
			withFaultFixtureTime(r, until.Add(-providerBreakerBaseCooldown), func() {
				for range providerBreakerConsecTrip {
					r.RecordProviderOutcome(id, false, 500, "internal error")
				}
			})
		}, true, false},
		{"ejection", func(r *Registry, id string, until time.Time) {
			withFaultFixtureTime(r, until.Add(-healthEjectionBaseCooldown), func() {
				for range healthEjectionConsecTrip {
					r.RecordProviderSessionServeOutcome(id, false, 500, "internal error")
				}
			})
		}, true, false},
		{"capacity", func(r *Registry, id string, until time.Time) {
			cfg := r.faults.Policy().CapacityCooldown
			withFaultFixtureTime(r, until.Add(-cfg.BaseTTL), func() {
				for range cfg.Threshold {
					r.RecordCapacityRejectLifecycle(id, "m")
				}
			})
		}, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := newClockedFaultRegistry(t)
			p1 := makeSchedulerProvider(t, reg, "classify-rebind-1", "m", 100)
			p2 := makeSchedulerProvider(t, reg, "classify-rebind-2", "m", 100)
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-CLASSIFY"}
			p1.SetAttestationResult(identity)
			p2.SetAttestationResult(identity)
			now := time.Now()
			tc.set(reg, p1.ID, now.Add(time.Minute))
			// The snapshot rejected p1, then classification loaded its shared
			// gate. Enrichment occurs before classification reads that gate.
			reg.mu.RLock()
			var snapshot routingSnapshot
			ok, _ := reg.snapshotProviderIntoLockedEx(&snapshot, p1, "m", RequestTraits{}, false, false, now)
			reg.mu.RUnlock()
			if ok {
				t.Fatal("precondition: the snapshot must reject the provider")
			}
			view := reg.gateViewOf(p1)
			p1.SetAttestationResult(&attestation.VerificationResult{
				Valid: true, PublicKey: identity.PublicKey, SerialNumber: "SER-CLASSIFY",
			})
			if view.g.SameGate(reg.gateOf(p1)) || !view.g.SameGate(reg.gateOf(p2)) ||
				view.g.BreakerOpenAt(now.UnixNano()) || view.g.EjectedAt(now.UnixNano()) || view.g.CapacityCooled("m", now) {
				t.Fatal("precondition: the loaded source must be the sibling's emptied gate")
			}
			reg.mu.RLock()
			breaker, capacity := reg.classifyRejectedProvider(view, "m", RequestTraits{}, false, false, now)
			reg.mu.RUnlock()
			if breaker != tc.breaker || capacity != tc.capacity {
				t.Fatalf("classification = breaker:%v capacity:%v, want %v/%v", breaker, capacity, tc.breaker, tc.capacity)
			}
			breakerCount, capacityCount := 0, 0
			if breaker {
				breakerCount++
			}
			if capacity {
				capacityCount++
			}
			if shouldBypassBreakerFailOpen(nil, breakerCount, capacityCount, 0) != tc.breaker {
				t.Fatal("moved gate produced the wrong fail-open rescan decision")
			}
		})
	}
}

func TestRejectedProviderClassificationKeepsDrainTransient(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "classify-draining", "m", 100)
	p.mu.Lock()
	p.drainingUntil = time.Now().Add(time.Minute)
	p.mu.Unlock()
	reg.mu.RLock()
	scan := reg.scanCandidatesLocked("m", &PendingRequest{Model: "m", RequestedMaxTokens: 32}, false)
	reg.mu.RUnlock()
	if scan.candidateCount != 0 || scan.capacityRejections != 1 || scan.breakerRejected != 0 {
		t.Fatalf("draining scan = candidates:%d capacity:%d breaker:%d", scan.candidateCount, scan.capacityRejections, scan.breakerRejected)
	}
	p.mu.Lock()
	p.RuntimeVerified = false
	p.mu.Unlock()
	reg.mu.RLock()
	scan = reg.scanCandidatesLocked("m", &PendingRequest{Model: "m", RequestedMaxTokens: 32}, false)
	reg.mu.RUnlock()
	if scan.capacityRejections != 0 {
		t.Fatal("a draining provider that also fails structural gates counted as transient capacity")
	}
}
