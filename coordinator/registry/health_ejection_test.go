package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestStableProviderIdentityLocked_Precedence(t *testing.T) {
	if got := stableProviderIdentity(&Provider{AttestationResult: &attestation.VerificationResult{SerialNumber: "SER1", PublicKey: "PK1"}, AccountID: "acct1"}); got != "serial:SER1" {
		t.Errorf("serial must win; got %q", got)
	}
	if got := stableProviderIdentity(&Provider{AttestationResult: &attestation.VerificationResult{PublicKey: "PK1"}, AccountID: "acct1"}); got != "sekey:PK1" {
		t.Errorf("se-key second; got %q", got)
	}
	if got := stableProviderIdentity(&Provider{AccountID: "acct1"}); got != "acct:acct1" {
		t.Errorf("account third; got %q", got)
	}
	if got := stableProviderIdentity(&Provider{}); got != "" {
		t.Errorf("un-attestable must be empty (never ejected); got %q", got)
	}
}

// A zombie (served faults, ~0 success) is ejected on the consecutive-fault trip.
func TestHealthEjection_EjectsOnConsecutiveFaults(t *testing.T) {
	reg := New(testLogger())
	const sid = "serial:ZOMBIE"
	for i := 0; i < healthEjectionConsecTrip-1; i++ {
		if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 500, "boom"); ejected {
			t.Fatalf("ejected too early at fault %d", i+1)
		}
		if reg.HealthEjectionOpen(sid) {
			t.Fatalf("open too early at fault %d", i+1)
		}
	}
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 500, "boom"); !ejected {
		t.Fatal("must eject on the consecTrip-th served fault")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("must be ejected (open) after the trip")
	}
}

// Capacity sheds (503 token_budget) and client 4xx are healthy/neutral and must
// NEVER eject — the breaker only counts genuine served faults.
func TestHealthEjection_CapacityAndClientNeutral(t *testing.T) {
	reg := New(testLogger())
	const sid = "serial:BUSY"
	for i := 0; i < 30; i++ {
		reg.RecordProviderServeOutcome(sid, false, 503, "token_budget_exhausted: request exceeds active token budget")
		reg.RecordProviderServeOutcome(sid, false, 400, "invalid tool payload")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("capacity-503 + client-400 must never eject a node")
	}
}

// Half-open recovery: a success after ejection clears the quarantine.
func TestHealthEjection_RecoverOnSuccess(t *testing.T) {
	reg := New(testLogger())
	const sid = "serial:RECOVER"
	for i := 0; i < healthEjectionConsecTrip; i++ {
		reg.RecordProviderServeOutcome(sid, false, 502, "backend crashed")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: must be ejected")
	}
	if _, recovered := reg.RecordProviderServeOutcome(sid, true, 200, ""); !recovered {
		t.Fatal("a success must recover an ejected identity")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("must no longer be ejected after recovery")
	}
}

// The ejection state is keyed by STABLE identity and is independent of the
// per-session node-health breaker, so it survives reconnect churn: a fresh
// session UUID's breaker is empty while the stable-id ejection persists.
func TestHealthEjection_SurvivesSessionChurn(t *testing.T) {
	reg := New(testLogger())
	const sid = "serial:CHURN"
	for i := 0; i < healthEjectionConsecTrip; i++ {
		reg.RecordProviderServeOutcome(sid, false, 500, "boom")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: ejected")
	}
	// A brand-new session UUID's per-session breaker is independent/empty...
	if reg.ProviderBreakerOpen("fresh-session-uuid") {
		t.Fatal("new session breaker must be empty")
	}
	// ...yet the stable-identity ejection remains in force across the reconnect.
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("stable-identity ejection must persist across session churn")
	}
}

func TestHealthEjection_KillSwitch(t *testing.T) {
	t.Setenv("EIGENINFERENCE_HEALTH_EJECTION", "off")
	reg := New(testLogger())
	const sid = "serial:OFF"
	for i := 0; i < healthEjectionConsecTrip+5; i++ {
		reg.RecordProviderServeOutcome(sid, false, 500, "boom")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("kill switch off must disable ejection entirely")
	}
}
