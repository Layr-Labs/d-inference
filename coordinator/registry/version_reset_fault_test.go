package registry

import "testing"

func TestVersionResetRetainsGenuine502BeforeAndAfterReconnect(t *testing.T) {
	for _, afterReset := range []bool{false, true} {
		name := "faults_before_reset"
		if afterReset {
			name = "late_faults_after_reset"
		}
		t.Run(name, func(t *testing.T) {
			r := New(testLogger())
			bindVersionedSession(t, r, "old", "0.9.0", true)
			recordFaults := func() {
				for range 8 {
					r.RecordInferenceError("old", "m", 502, "base")
					r.RecordProviderOutcome("old", false, 502, "encryption failure")
					r.RecordProviderSessionServeOutcome("old", false, 502, "encryption failure")
				}
			}
			if !afterReset {
				recordFaults()
			}
			dropAbruptlyUnrecorded(t, r, "old")
			bindVersionedSession(t, r, "new", "0.9.1", false)
			if afterReset {
				recordFaults()
			}
			assertIdentityQuarantine(t, r, "new", true)
			if r.IsSupersededDisconnectFlush("old", 502) {
				t.Fatal("status-only 502 was classified as a coordinator disconnect flush")
			}
		})
	}
}
