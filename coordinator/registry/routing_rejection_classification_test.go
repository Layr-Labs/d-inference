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
		set               func(*gateState, time.Time)
		breaker, capacity bool
	}{
		{"breaker", func(g *gateState, until time.Time) { g.breakerUntil = until }, true, false},
		{"ejection", func(g *gateState, until time.Time) { g.ejectionUntil = until }, true, false},
		{"capacity", func(g *gateState, until time.Time) {
			g.capacityCooldowns["m"] = &capacityCooldownEntry{expiry: until}
		}, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			p1 := makeSchedulerProvider(t, reg, "classify-rebind-1", "m", 100)
			p2 := makeSchedulerProvider(t, reg, "classify-rebind-2", "m", 100)
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-CLASSIFY"}
			p1.SetAttestationResult(identity)
			p2.SetAttestationResult(identity)
			now := time.Now()
			withGateForSession(reg, p1.ID, func(g *gateState) { tc.set(g, now.Add(time.Minute)) })
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
			if view.g == p1.gate.Load() || view.g != p2.gate.Load() ||
				view.g.breakerOpenAt(now.UnixNano()) || view.g.ejectedAt(now.UnixNano()) || view.g.capacityCooled("m", now) {
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
