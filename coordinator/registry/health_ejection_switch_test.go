package registry

import "testing"

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
		if got := parseHealthEjectionEnv(raw); got != want {
			t.Errorf("parseHealthEjectionEnv(%q) = %v, want %v", raw, got, want)
		}
	}
}

// TestHealthEjectionSwitchHookRestores pins the test hook contract: the flip
// is visible through healthEjectionEnabled immediately, and the previous state
// comes back when the (sub)test finishes so tests cannot leak the kill switch
// into each other.
func TestHealthEjectionSwitchHookRestores(t *testing.T) {
	before := healthEjectionEnabled()
	t.Run("flip", func(t *testing.T) {
		setHealthEjectionEnabledForTest(t, !before)
		if healthEjectionEnabled() != !before {
			t.Fatalf("hook did not flip the switch")
		}
		// The gate consults the cached switch, not the environment: setting the
		// variable here must have no effect.
		if before {
			t.Setenv(healthEjectionEnvKey, "on")
		} else {
			t.Setenv(healthEjectionEnvKey, "off")
		}
		if healthEjectionEnabled() != !before {
			t.Fatalf("environment change leaked into the cached switch")
		}
	})
	if healthEjectionEnabled() != before {
		t.Fatalf("hook did not restore the switch after the subtest")
	}
}

// TestHealthEjectionSwitchGatesRouting proves the routing gate honors the
// cached switch: an ejected identity is derouted while the switch is on and
// routable again once it is off (recording is disabled too, so a fresh
// registry with the switch off never ejects — see TestHealthEjection_KillSwitch).
func TestHealthEjectionSwitchGatesRouting(t *testing.T) {
	setHealthEjectionEnabledForTest(t, true)
	reg := New(testLogger())
	const model, serial = "switch-model", "SER-SWITCH"
	attestSchedulerProvider(t, reg, "sess-1", model, serial, 100)
	sid := "serial:" + serial
	for i := 0; i < healthEjectionConsecTrip+1; i++ {
		reg.RecordProviderServeOutcome(sid, false, 500, "boom")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: identity ejected")
	}
	// The scan (not the preflight, which fails open on breaker-class gates)
	// is where the ejection gate bites; breakerRejected is its tally.
	scan := func() candidateScan {
		pr := &PendingRequest{RequestID: "switch", Model: model, RequestedMaxTokens: 16}
		reg.mu.RLock()
		defer reg.mu.RUnlock()
		return reg.scanCandidatesLocked(model, pr, false)
	}
	if got := scan(); got.candidateCount != 0 || got.breakerRejected != 1 {
		t.Fatalf("switch on: candidates=%d breakerRejected=%d, want 0/1",
			got.candidateCount, got.breakerRejected)
	}
	setHealthEjectionEnabledForTest(t, false)
	if got := scan(); got.candidateCount != 1 || got.breakerRejected != 0 {
		t.Fatalf("switch off: candidates=%d breakerRejected=%d, want 1/0",
			got.candidateCount, got.breakerRejected)
	}
}
