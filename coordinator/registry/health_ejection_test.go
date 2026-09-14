package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// expireHealthEjection rewinds the identity's ejection expiry into the past,
// simulating the cooldown elapsing (ejected -> half-open) without sleeping.
func expireHealthEjection(reg *Registry, sid string) {
	s := reg.faults.StatusForKey(sid, "", "")
	advanceFaultFixtureTime(reg, time.Until(s.EjectionUntil)+time.Second)
}

func healthEjectionTripsOf(reg *Registry, sid string) (trips int) {
	return reg.faults.StatusForKey(sid, "", "").EjectionTrips
}

func TestStableProviderIdentityLocked_Precedence(t *testing.T) {
	if got := stableProviderIdentityLocked(&Provider{AttestationResult: &attestation.VerificationResult{Valid: true, SerialNumber: "SER1", PublicKey: "PK1"}, AccountID: "acct1"}); got != "serial:SER1" {
		t.Errorf("serial must win; got %q", got)
	}
	if got := stableProviderIdentityLocked(&Provider{AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: "PK1"}, AccountID: "acct1"}); got != "sekey:PK1" {
		t.Errorf("se-key second; got %q", got)
	}
	if got := stableProviderIdentityLocked(&Provider{AccountID: "acct1"}); got != "acct:acct1" {
		t.Errorf("account third; got %q", got)
	}
	if got := stableProviderIdentityLocked(&Provider{}); got != "" {
		t.Errorf("un-attestable must be empty (never ejected); got %q", got)
	}
	// An INVALID attestation result carries attacker-supplied blob fields —
	// serial and SE key must be ignored, leaving only the token-authenticated
	// account fallback (or nothing).
	if got := stableProviderIdentityLocked(&Provider{AttestationResult: &attestation.VerificationResult{Valid: false, SerialNumber: "SER-VICTIM", PublicKey: "PK1"}, AccountID: "acct1"}); got != "acct:acct1" {
		t.Errorf("invalid attestation must fall through to the account; got %q", got)
	}
	if got := stableProviderIdentityLocked(&Provider{AttestationResult: &attestation.VerificationResult{Valid: false, SerialNumber: "SER-VICTIM", PublicKey: "PK1"}}); got != "" {
		t.Errorf("invalid attestation without an account must yield no identity; got %q", got)
	}
}

func TestHealthEjection_KillSwitch(t *testing.T) {
	setHealthEjectionEnabledForTest(t, false)
	reg := New(testLogger())
	const sid = "serial:OFF"
	for i := 0; i < healthEjectionConsecTrip+5; i++ {
		reg.RecordProviderServeOutcome(sid, false, 500, "boom")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("kill switch off must disable ejection entirely")
	}
}

// Codex P1: after Disconnect removes the provider, the trailing 502-disconnect
// faults must still resolve the stable identity (via the disconnect cache) so they
// are recorded against the breaker — otherwise the dominant zombie signal is lost.
func TestGetProviderStableIdentity_DisconnectFallback(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "sess-1", "m", 50)
	p.mu.Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "SER-Z"}
	p.mu.Unlock()
	if got := reg.GetProviderStableIdentity("sess-1"); got != "serial:SER-Z" {
		t.Fatalf("connected lookup: got %q want serial:SER-Z", got)
	}
	reg.Disconnect("sess-1") // removes from r.providers; cache must still resolve
	if got := reg.GetProviderStableIdentity("sess-1"); got != "serial:SER-Z" {
		t.Fatalf("post-disconnect fallback: got %q want serial:SER-Z (zombie disconnect faults would be lost)", got)
	}
}

// Codex P1: if health-ejection skips the only provider for a model, the fail-open
// rescan (which bypasses ejection) must still return it — never zero out the model.
func TestHealthEjection_FailOpenWhenAllEjected(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "only", "m", 50)
	p.mu.Lock()
	p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "SOLO"}
	p.mu.Unlock()
	for i := 0; i < healthEjectionConsecTrip; i++ {
		reg.RecordProviderServeOutcome("serial:SOLO", false, 500, "boom")
	}
	if !reg.HealthEjectionOpen("serial:SOLO") {
		t.Fatal("precondition: must be ejected")
	}
	if got := reserveOne(reg, "m", 100); got == nil {
		t.Fatal("fail-open: the only provider for a model must still be reservable when ejected")
	}
}

// A box mid-way through a long generation that sheds concurrent dispatches
// must keep vouching for itself at FIRST CONTENT, not only at completion:
// RecordCapacityAccept (called by commitFirstContent) clears the node-level
// capacity streak, so transient fullness during a long stream can never
// accumulate to the zero-accepts black-hole ejection.
func TestHealthEjection_FirstContentClearsCapacityStreak(t *testing.T) {
	reg := New(testLogger())
	const model = "streak-model"
	const capacityReject = "token_budget_exhausted: request exceeds active token budget"

	p := attestSchedulerProvider(t, reg, "sess-streak", model, "SER-STREAK", 100)
	sid := reg.GetProviderStableIdentity(p.ID)
	if sid == "" {
		t.Fatal("attested provider must have a stable identity")
	}

	for i := 0; i < healthEjectionCapacityConsecTrip-1; i++ {
		if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); ejected {
			t.Fatalf("ejected too early at capacity reject %d", i+1)
		}
	}
	// First content chunk on a concurrent request — the box IS serving.
	reg.RecordCapacityAccept(p.ID, model)

	for i := 0; i < healthEjectionCapacityConsecTrip-1; i++ {
		if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); ejected {
			t.Fatalf("streak must have been cleared by the first-content accept (reject %d post-accept)", i+1)
		}
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("a box producing content must never trip the capacity black-hole ejection")
	}
}

// Codex P2: first content on a capacity-ejected node must DISARM the capacity
// half-open instant re-arm, not just the streak. Scenario: node capacity-
// ejected once; cooldown expires; the half-open probe produces first content
// (the node accepts work); a single concurrent capacity-shaped reject then
// arrives — it must need a full fresh zero-success streak, not re-eject in one
// strike off the stale trips/lastTripCapacity state.
func TestHealthEjection_FirstContentDisarmsCapacityHalfOpen(t *testing.T) {
	reg := newClockedFaultRegistry(t)
	const model = "halfopen-model"
	const capacityReject = "token_budget_exhausted: request exceeds active token budget"

	p := attestSchedulerProvider(t, reg, "sess-halfopen", model, "SER-HALFOPEN", 100)
	sid := reg.GetProviderStableIdentity(p.ID)
	if sid != "serial:SER-HALFOPEN" {
		t.Fatalf("stable identity = %q, want serial:SER-HALFOPEN", sid)
	}

	for i := 0; i < healthEjectionCapacityConsecTrip; i++ {
		reg.RecordProviderServeOutcome(sid, false, 503, capacityReject)
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: zero-success capacity streak must eject")
	}

	// Cooldown expires (half-open) and the probe produces FIRST CONTENT.
	expireHealthEjection(reg, sid)
	reg.RecordCapacityAccept(p.ID, model)

	// One straggling capacity reject must NOT re-eject a node that just
	// proved it accepts work.
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); ejected {
		t.Fatal("a single capacity reject after first content re-ejected via stale half-open state")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("node must stay routable after first content plus one capacity shed")
	}

	// The black-hole backstop is intact: a full fresh zero-success streak
	// still ejects.
	for i := 0; i < healthEjectionCapacityConsecTrip-2; i++ {
		if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); ejected {
			t.Fatalf("ejected before the full fresh streak at reject %d", i+2)
		}
	}
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); !ejected {
		t.Fatal("a full fresh zero-success streak must still eject")
	}
}

// Counter-case for the half-open disarm: first content must NOT touch a
// FAULT-shaped ejection's backoff memory — content says nothing about fault
// behavior, and clearing trips on any served chunk would let a flapping node
// reset its exponential backoff forever. The next fault after cooldown expiry
// must still insta-re-arm (fault half-open unchanged).
func TestHealthEjection_FirstContentPreservesFaultHalfOpen(t *testing.T) {
	reg := newClockedFaultRegistry(t)
	const model = "faulty-model"

	p := attestSchedulerProvider(t, reg, "sess-faulty", model, "SER-FAULTY", 100)
	sid := reg.GetProviderStableIdentity(p.ID)

	for i := 0; i < healthEjectionConsecTrip; i++ {
		reg.RecordProviderServeOutcome(sid, false, 500, "internal error")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("precondition: consecutive faults must eject")
	}

	reg.RecordCapacityAccept(p.ID, model)

	expireHealthEjection(reg, sid)
	trips := healthEjectionTripsOf(reg, sid)
	if trips == 0 {
		t.Fatal("first content must not wipe a fault ejection's trip count")
	}
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 500, "internal error"); !ejected {
		t.Fatal("the next fault in fault half-open must still insta-re-arm")
	}
}
