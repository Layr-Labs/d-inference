package registry_test

import (
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/configswitch"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestParseHealthEjectionEnv(t *testing.T) {
	cases := map[string]bool{
		"":        true,
		"on":      true,
		"ON":      true,
		"1":       true,
		"true":    true,
		"yes":     true,
		"garbage": true,
		"off":     false,
		" OFF ":   false,
		"0":       false,
		"false":   false,
		"False":   false,
		"no":      false,
		"\tno\n":  false,
	}
	for raw, want := range cases {
		if got := configswitch.Parse(raw); got != want {
			t.Errorf("parseHealthEjectionEnv(%q) = %v, want %v", raw, got, want)
		}
	}
}

// The cached policy changes immediately and is restored on subtest cleanup;
// changing the environment after construction must not alter it.
func TestHealthEjectionSwitchHookRestores(t *testing.T) {
	policy := configswitch.New(os.Getenv(configswitch.HealthEjectionEnvKey))
	before := policy.Load()
	t.Run("flip", func(t *testing.T) {
		previous := policy.Swap(!before)
		t.Cleanup(func() { policy.Store(previous) })
		if policy.Load() != !before {
			t.Fatalf("hook did not flip the switch")
		}
		if before {
			t.Setenv(configswitch.HealthEjectionEnvKey, "on")
		} else {
			t.Setenv(configswitch.HealthEjectionEnvKey, "off")
		}
		if policy.Load() != !before {
			t.Fatalf("environment change leaked into the cached switch")
		}
	})
	if policy.Load() != before {
		t.Fatalf("hook did not restore the switch after the subtest")
	}
}

// The selection scan honors the live cached switch, including re-admission
// of an already-ejected identity when ejection is disabled.
func TestHealthEjectionSwitchGatesRouting(t *testing.T) {
	policy := configswitch.New("on")
	options := identitygate.DefaultOptions()
	options.HealthEjectionEnabled = policy.Load
	gates := identitygate.New(testLogger(), &options)
	var planner *production.ReservationPlanner
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		IdentityGates: gates,
		Reservations: func(p *production.ReservationPlanner) production.ReservationPreparation {
			planner = p
			return p
		},
	})
	const model, serial = "switch-model", "SER-SWITCH"
	attestSchedulerProvider(t, reg, "sess-1", model, serial, 100)
	sid := "serial:" + serial
	for i := 0; i < healthEjectionConsecTrip+1; i++ {
		reg.RecordProviderServeOutcome(sid, false, 500, "boom")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: identity ejected")
	}
	// The scan, not the fail-open preflight, accounts for ejection rejection.
	scan := func() production.CandidateScan {
		pr := &production.PendingRequest{RequestID: "switch", Model: model, RequestedMaxTokens: 16}
		return planner.ScanCandidates(model, pr, false)
	}
	if got := scan(); got.CandidateCount != 0 || got.BreakerRejected != 1 {
		t.Fatalf("switch on: candidates=%d breakerRejected=%d, want 0/1",
			got.CandidateCount, got.BreakerRejected)
	}
	policy.Store(false)
	if got := scan(); got.CandidateCount != 1 || got.BreakerRejected != 0 {
		t.Fatalf("switch off: candidates=%d breakerRejected=%d, want 1/0",
			got.CandidateCount, got.BreakerRejected)
	}
}
