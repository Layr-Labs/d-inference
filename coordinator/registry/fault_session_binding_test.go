package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A retained Provider pointer may finish attestation or version handling after
// its connection was removed and the same session ID registered again. Those
// operations must not move or reset either connection's identity history.
func TestFaultStateRetiredProviderCannotRebindOrResetReplacement(t *testing.T) {
	reg := New(testLogger())
	const id, model = "reused-session", "m"
	const oldIdentity, currentIdentity = "serial:OLD-CONNECTION", "serial:CURRENT-CONNECTION"
	old := attestSchedulerProvider(t, reg, id, model, "OLD-CONNECTION", 100)
	old.SetVersion("0.9.0")
	for range 8 {
		reg.RecordInferenceError(id, model, 502, "base", protocol.CoordinatorCauseProviderDisconnected)
		reg.RecordProviderOutcome(id, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
		reg.RecordProviderSessionServeOutcome(id, false, 502, "provider disconnected", protocol.CoordinatorCauseProviderDisconnected)
	}
	assertOldHistory := func() {
		t.Helper()
		if !reg.ProviderBreakerOpen(oldIdentity) || !reg.HealthEjectionOpen(oldIdentity) ||
			!reg.InferenceErrorCooldownActive(oldIdentity, model, "base") {
			t.Fatal("the retired connection's fault history moved or reset")
		}
	}
	assertOldHistory()
	reg.DisconnectWithReason(id, DisconnectReasonReadError)
	current := attestSchedulerProvider(t, reg, id, model, "CURRENT-CONNECTION", 100)
	current.SetVersion("0.9.0")
	if current == old || reg.GetProvider(id) != current {
		t.Fatal("same-ID registration did not install a distinct current Provider")
	}

	old.SetVersion("0.9.1")
	assertOldHistory()
	old.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "CURRENT-CONNECTION"})
	old.RebindStableFaultKey()
	assertOldHistory()
	if got := reg.GetProviderStableIdentity(id); got != currentIdentity {
		t.Fatalf("current identity = %q, want %q", got, currentIdentity)
	}
	if reg.ProviderBreakerOpen(id) || reg.HealthEjectionOpen(currentIdentity) ||
		reg.InferenceErrorCooldownActive(id, model, "base") {
		t.Fatal("late old-connection operations poisoned the replacement")
	}

	request := &PendingRequest{RequestID: "replacement-route", Model: model, RequestedMaxTokens: 64}
	selected, decision := reg.ReserveProviderEx(model, request)
	if selected != current || decision.CandidateCount != 1 {
		t.Fatalf("reservation = %v with %d candidates, want the current connection alone", selected, decision.CandidateCount)
	}
	selected.RemovePending(request.RequestID)
}
