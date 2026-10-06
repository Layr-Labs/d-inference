package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerdrain"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

func TestRejectedProviderClassificationFollowsSharedRebind(t *testing.T) {
	for _, tc := range []struct {
		name              string
		breaker, capacity bool
	}{
		{"breaker", true, false},
		{"ejection", true, false},
		{"capacity", false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Now()
			clock := &faultGateClock{at: now}
			options := identitygate.DefaultOptions()
			options.Now = clock.Now
			options.HealthEjectionEnabled = func() bool { return true }
			gates := identitygate.New(testLogger(), &options)
			var planner *production.ReservationPlanner
			reg := production.NewWithDependencies(testLogger(), production.Dependencies{
				IdentityGates: gates,
				Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
					planner = actual
					return actual
				},
			})
			p1 := makeSchedulerProvider(t, reg, "classify-rebind-1", "m", 100)
			p2 := makeSchedulerProvider(t, reg, "classify-rebind-2", "m", 100)
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-CLASSIFY"}
			p1.SetAttestationResult(identity)
			p2.SetAttestationResult(identity)
			switch tc.name {
			case "breaker":
				for i := 0; i < identitygate.ProviderBreakerConsecTrip; i++ {
					gates.RecordProviderOutcome(p1.ID, false, 500, "internal fault")
				}
			case "ejection":
				for i := 0; i < 8; i++ {
					gates.RecordProviderSessionServeOutcome(p1.ID, false, 500, "internal fault")
				}
			case "capacity":
				// The default two-minute cooldown starts one minute earlier, so
				// every branch has the original now+one-minute expiry.
				clock.Set(now.Add(-time.Minute))
				for i := 0; i < identitygate.DefaultCapacityCooldownThreshold; i++ {
					reg.RecordCapacityReject(p1.ID, "m")
				}
				clock.Set(now)
			}
			lease := planner.PrepareEligibility()
			ok, _ := lease.Routing(p1.ID, "m", production.RequestTraits{}, false, now, false, false)
			lease.Close()
			if ok {
				t.Fatal("precondition: the snapshot must reject the provider")
			}
			view := gates.ViewReference(gates.ResolveSession(p1.ID, false))
			p1.SetAttestationResult(&attestation.VerificationResult{
				Valid: true, PublicKey: identity.PublicKey, SerialNumber: "SER-CLASSIFY",
			})
			if view.SameIdentity(gates.ViewReference(gates.ResolveSession(p1.ID, false))) ||
				!view.SameIdentity(gates.ViewReference(gates.ResolveSession(p2.ID, false))) ||
				view.BreakerOpenAt(now.UnixNano()) || view.EjectedAt(now.UnixNano()) || view.CapacityCooled("m", now) {
				t.Fatal("precondition: the loaded source must be the sibling's emptied gate")
			}
			lease = planner.PrepareEligibility()
			breaker, capacity := view.ClassifyRejection("m", now, false,
				func() string { return "serial:SER-CLASSIFY" }, func() bool { return false },
				func() bool {
					ok, _ := lease.Routing(p1.ID, "m", production.RequestTraits{}, false, now, false, true)
					return ok
				})
			lease.Close()
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
			if selection.BypassBreaker(false, breakerCount, capacityCount, 0) != tc.breaker {
				t.Fatal("moved gate produced the wrong fail-open rescan decision")
			}
		})
	}
}

func TestRejectedProviderClassificationKeepsDrainTransient(t *testing.T) {
	drain := new(providerdrain.Authority)
	var planner *production.ReservationPlanner
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		ProviderDrains: func(string) *providerdrain.Authority { return drain },
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		},
	})
	p := makeSchedulerProvider(t, reg, "classify-draining", "m", 100)
	p.Mu().Lock()
	drain.Mark(time.Now().Add(time.Minute - providerdrain.TTL))
	p.Mu().Unlock()
	scan := planner.ScanCandidates("m", &production.PendingRequest{Model: "m", RequestedMaxTokens: 32}, false)
	if scan.CandidateCount != 0 || scan.CapacityRejections != 1 || scan.BreakerRejected != 0 {
		t.Fatalf("draining scan = candidates:%d capacity:%d breaker:%d", scan.CandidateCount, scan.CapacityRejections, scan.BreakerRejected)
	}
	p.Mu().Lock()
	p.RuntimeVerified = false
	p.Mu().Unlock()
	scan = planner.ScanCandidates("m", &production.PendingRequest{Model: "m", RequestedMaxTokens: 32}, false)
	if scan.CapacityRejections != 0 {
		t.Fatal("a draining provider that also fails structural gates counted as transient capacity")
	}
}
