package faultstate

import (
	"fmt"
	"testing"
	"time"
)

// REQUIRED: stale identities expire — an identity whose only state is a
// capacity streak older than the window is idle, and the gate sweep drops it
// once no live session references it and the idle grace has passed.
func TestHealthEjectionCapacityStreakSweep(t *testing.T) {
	reg := newTestManager(testLogger())
	const rejectStr = "token_budget_exhausted: request exceeds active token budget"
	for i := 0; i < 2100; i++ {
		reg.RecordProviderServeOutcome(fmt.Sprintf("serial:churned-%d", i), false, 503, rejectStr)
	}
	if n := reg.gateCount(); n < 2050 {
		t.Fatalf("setup produced too few streak gates: %d", n)
	}

	// A live identity records just before the sweep runs far enough in the
	// future for the churned streaks to have aged out; its own fresh streak
	// (touched now) keeps it.
	future := time.Now().Add(gateIdleGrace + healthEjectionWindow + time.Second)
	withGateForKey(reg, "serial:live", func(g *gateState) {
		g.ejectionCapacityStreak = capacityStreak{n: 1, last: future}
		g.touched = future
	})
	reg.sweepGates(future)

	if after := reg.gateCount(); after != 1 {
		t.Fatalf("sweep must drop every stale identity, leaving only the live one; got %d", after)
	}
}

// A stale capacity streak (older than the window) must not combine with a
// fresh blip: 9 old strikes + 1 fresh one is NOT a black hole.
func TestHealthEjectionCapacityStreakStaleReset(t *testing.T) {
	reg := newTestManager(testLogger())
	const sid = "serial:STALE"
	const rejectStr = "token_budget_exhausted: request exceeds active token budget"
	for i := 0; i < healthEjectionCapacityConsecTrip-1; i++ {
		reg.RecordProviderServeOutcome(sid, false, 503, rejectStr)
	}
	withGateForKey(reg, sid, func(g *gateState) {
		g.ejectionCapacityStreak.last = g.ejectionCapacityStreak.last.Add(-(healthEjectionWindow + time.Second))
	})

	if ejected, _ := reg.RecordProviderServeOutcome(sid, false, 503, rejectStr); ejected {
		t.Fatal("a fresh strike after a stale streak must restart the count, not eject")
	}
	if reg.HealthEjectionOpen(sid) {
		t.Fatal("identity must not be ejected off a stale streak")
	}
}

// The node-capacity-strike classifier: capacity-shaped 5xx count, request-shape
// context overflows and client/fault shapes do not.
func TestIsNodeCapacityRejectStrike(t *testing.T) {
	cases := []struct {
		code int
		err  string
		want bool
	}{
		{503, "token_budget_exhausted: request exceeds active token budget", true},
		{503, "token_budget_exhausted: insufficient global KV cache headroom", true},
		{503, "request queue full", true},
		{503, "server busy", true},
		{500, "token_budget_exhausted", true},
		{502, "insufficient KV headroom", true},
		{504, "request timed out waiting for capacity", true},
		// Request-shape context overflows indict the request, not the node.
		{503, "token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)", false},
		{503, "context length exceeded", false},
		{503, "prompt too long for context window", false},
		// Faults are owned by the fault path, client shapes are neutral.
		{503, "internal error", false},
		{500, "panic: index out of range", false},
		{400, "token budget", false},
		{429, "queue full", false},
	}
	for _, c := range cases {
		if got := isNodeCapacityRejectStrike(c.code, c.err); got != c.want {
			t.Errorf("isNodeCapacityRejectStrike(%d, %q)=%v, want %v", c.code, c.err, got, c.want)
		}
	}
}
