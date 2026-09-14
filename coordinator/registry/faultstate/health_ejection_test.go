package faultstate

import (
	"testing"
	"time"
)

// A zombie (served faults, ~0 success) is ejected on the consecutive-fault trip.
func TestHealthEjection_EjectsOnConsecutiveFaults(t *testing.T) {
	reg := newTestManager(testLogger())
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

// A busy-but-SERVING box must never be ejected: capacity sheds interleaved
// with successes reset the capacity streak, and client 4xx are always neutral.
func TestHealthEjection_CapacityAndClientNeutral(t *testing.T) {
	reg := newTestManager(testLogger())
	const capacityReject = "token_budget_exhausted: request exceeds active token budget"

	// Busy-but-serving: bursts of capacity rejects below the streak threshold,
	// each broken by a served request. Runs forever without ejecting.
	const busy = "serial:BUSY"
	for round := 0; round < 10; round++ {
		for i := 0; i < healthEjectionCapacityConsecTrip-1; i++ {
			if ejected, _ := reg.RecordProviderServeOutcome(busy, false, 503, capacityReject); ejected {
				t.Fatalf("round %d: capacity shed %d ejected a serving node", round, i+1)
			}
		}
		reg.RecordProviderServeOutcome(busy, true, 200, "")
	}
	if reg.HealthEjectionOpen(busy) {
		t.Fatal("capacity sheds interleaved with successes must never eject a node")
	}

	// Client-shape 4xx never count toward anything, in any volume.
	const clientErrs = "serial:CLIENT"
	for i := 0; i < 50; i++ {
		reg.RecordProviderServeOutcome(clientErrs, false, 400, "invalid tool payload")
		reg.RecordProviderServeOutcome(clientErrs, false, 429, "rate limited")
	}
	if reg.HealthEjectionOpen(clientErrs) {
		t.Fatal("client 4xx must never eject a node")
	}

	// Request-shape context overflows indict the request, not the node.
	const ctxSid = "serial:CTX"
	for i := 0; i < 50; i++ {
		reg.RecordProviderServeOutcome(ctxSid, false, 503,
			"token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)")
	}
	if reg.HealthEjectionOpen(ctxSid) {
		t.Fatal("oversized-prompt rejections must never eject a node")
	}
}

// The prod black hole (2026-07-03, provider f21d71d7): 13,333 capacity-shaped
// 503s at a 100% error rate with zero successes, never ejected — every fault
// breaker treats capacity sheds as neutral. A pure zero-success capacity
// streak must now eject at healthEjectionCapacityConsecTrip.
func TestHealthEjection_CapacityBlackHoleEjects(t *testing.T) {
	reg := newTestManager(testLogger())
	const sid = "serial:BLACKHOLE"
	const capacityReject = "token_budget_exhausted: request exceeds active token budget"
	for i := 0; i < healthEjectionCapacityConsecTrip-1; i++ {
		if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); ejected {
			t.Fatalf("ejected too early at capacity reject %d", i+1)
		}
	}
	ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject)
	if !ejected {
		t.Fatalf("must eject on the %dth zero-success capacity reject", healthEjectionCapacityConsecTrip)
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("must be ejected (open) after the capacity-streak trip")
	}

	// Half-open: after the cooldown elapses, a probe that capacity-rejects
	// re-arms immediately with a doubled backoff...
	expireHealthEjection(reg, sid)
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("cooldown expiry must allow a half-open probe")
	}
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); !ejected {
		t.Fatal("a capacity reject on the half-open probe must re-arm the ejection")
	}
	// ...and a probe that SUCCEEDS recovers the node and clears the streak.
	expireHealthEjection(reg, sid)
	if _, recovered := reg.RecordProviderServeOutcome(sid, true, 200, ""); !recovered {
		t.Fatal("a successful probe must recover the ejected identity")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("must no longer be ejected after recovery")
	}
}

// Half-open recovery: a success after ejection clears the quarantine.
func TestHealthEjection_RecoverOnSuccess(t *testing.T) {
	reg := newTestManager(testLogger())
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
	reg := newTestManager(testLogger())
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

// A single capacity shed must NOT re-arm a FAULT ejection whose cooldown just
// expired: capacity rejects are legitimate for a healthy-but-full box, and the
// half-open instant re-arm applies only when the previous trip was itself
// capacity-shaped.
func TestHealthEjection_CapacityShedDoesNotRearmFaultEjection(t *testing.T) {
	reg := newTestManager(testLogger())
	const sid = "serial:FAULTY-BUT-FULL"
	const capacityReject = "token_budget_exhausted: request exceeds active token budget"

	for i := 0; i < healthEjectionConsecTrip; i++ {
		reg.RecordProviderServeOutcome(sid, false, 500, "internal error")
	}
	if !reg.HealthEjectionOpen(sid) {
		t.Fatal("consecutive faults must eject")
	}

	// Cooldown expires; the half-open probe hits a legitimately full box.
	expireHealthEjection(reg, sid)
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); ejected {
		t.Fatal("one capacity shed must not re-arm a fault ejection")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("node must stay routable after a single capacity shed in fault half-open")
	}

	// The zero-success capacity streak still protects against a true black
	// hole: the full streak ejects even in fault half-open.
	for i := 0; i < healthEjectionCapacityConsecTrip-2; i++ {
		if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); ejected {
			t.Fatalf("ejected before the full capacity streak at reject %d", i+2)
		}
	}
	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, capacityReject); !ejected {
		t.Fatal("the full zero-success capacity streak must still eject")
	}
}

// expireHealthEjection rewinds the identity's ejection expiry into the past,
// simulating the cooldown elapsing (ejected -> half-open) without sleeping.
func expireHealthEjection(reg *testManager, sid string) {
	withGateForKey(reg, sid, func(g *gateState) { g.ejectionUntil = time.Now().Add(-time.Second) })
}
