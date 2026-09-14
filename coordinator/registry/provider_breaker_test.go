package registry

import (
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/registry/faultstate"
	"sync"
	"testing"
	"time"
)

// --- test helpers (poke internal maps / call *Locked helpers, mirroring
// error_cooldown_test.go) ---

func providerBreakerOpenAt(r *Registry, id string, now time.Time) bool {
	return r.breakerOpen(id, now)
}

// providerHealthWindowOf returns the provider's node-health ring (nil when no
// fault or success was ever recorded).
func providerHealthWindowOf(r *Registry, id string) *faultstate.Status {
	s := r.faults.StatusForSession(id, "", "")
	if !s.BreakerPresent {
		return nil
	}
	return &s
}

// --- classifier unit tests ---

// --- breaker behavior ---

// The gate (providerPassesRoutingGatesLocked) must structurally exclude a
// breaker-open provider, and the fail-open bypass must let it back in.
func TestProviderPassesRoutingGatesBreakerBypass(t *testing.T) {
	reg := New(testLogger())
	model := "gate-bypass-model"
	p := makeSchedulerProvider(t, reg, "p", model, 100)
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 500, "")
	}
	now := time.Now()
	reg.mu.Lock()
	p.mu.Lock()
	honored := reg.providerPassesRoutingGatesLockedEx(p, model, RequestTraits{}, false, now, false, false)
	bypassed := reg.providerPassesRoutingGatesLockedEx(p, model, RequestTraits{}, false, now, true, false)
	p.mu.Unlock()
	reg.mu.Unlock()
	if honored {
		t.Fatal("breaker-open provider must FAIL the gate when the breaker is honored")
	}
	if !bypassed {
		t.Fatal("breaker-open provider must PASS the gate when the breaker is bypassed (fail open)")
	}
}

// The fail-open valve must trigger ONLY when the node-health breaker is the SOLE
// reason a request has no route. If a healthy provider was merely busy
// (capacityRejections) or too slow (ttftRejections), selection must surface that
// signal (queue / 429) instead of failing open to a known-bad, breaker-open node.
func TestShouldBypassBreakerFailOpen(t *testing.T) {
	cases := []struct {
		name            string
		winner          bool
		breakerRejected int
		capacity        int
		ttft            int
		want            bool
	}{
		{"winner found — no fail-open needed", true, 1, 0, 0, false},
		{"breaker played no part", false, 0, 0, 0, false},
		{"breaker is the sole reason", false, 1, 0, 0, true},
		{"healthy provider merely busy", false, 1, 1, 0, false},
		{"healthy provider too slow", false, 1, 0, 1, false},
		{"mixed fleet: busy + slow + breaker", false, 2, 3, 1, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var w *routingCandidate
			if c.winner {
				w = &routingCandidate{}
			}
			if got := shouldBypassBreakerFailOpen(w, c.breakerRejected, c.capacity, c.ttft); got != c.want {
				t.Fatalf("shouldBypassBreakerFailOpen(winner=%v, breaker=%d, cap=%d, ttft=%d)=%v, want %v",
					c.winner, c.breakerRejected, c.capacity, c.ttft, got, c.want)
			}
		})
	}
}

// End-to-end through the production dispatch hot path (ReserveProviderEx): a
// breaker-open provider is structurally excluded, but when EVERY provider for a
// model is breaker-open the fail-open safety valve must still return a candidate
// so a bad fleet-wide rollout cannot deroute the whole fleet.
func TestReserveProviderExNodeHealthBreakerFailsOpen(t *testing.T) {
	reg := New(testLogger())
	model := "node-health-model"
	bad := makeSchedulerProvider(t, reg, "bad", model, 200)  // faster: normally preferred
	good := makeSchedulerProvider(t, reg, "good", model, 50) // slower

	req := func(id string) *PendingRequest {
		return &PendingRequest{RequestID: id, Model: model, RequestedMaxTokens: 128}
	}

	// Trip ONLY the (faster) bad provider with fault-503s. Selection must fall to
	// the healthy provider despite the bad one's higher TPS.
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(bad.ID, false, 503, "internal error")
	}
	if !reg.ProviderBreakerOpen(bad.ID) {
		t.Fatal("bad provider's breaker must be open")
	}
	selected, decision := reg.ReserveProviderEx(model, req("r1"))
	if selected == nil || selected.ID != good.ID {
		t.Fatalf("selection must fall to the healthy provider, got %v", selected)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1 (breaker-open provider structurally excluded)", decision.CandidateCount)
	}
	good.RemovePending("r1")

	// Trip the good provider too: the ENTIRE fleet is now breaker-open.
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(good.ID, false, 500, "")
	}
	if !reg.ProviderBreakerOpen(good.ID) {
		t.Fatal("good provider's breaker must now be open too")
	}
	// FAIL OPEN: selection must still return a candidate.
	selected, _ = reg.ReserveProviderEx(model, req("r2"))
	if selected == nil {
		t.Fatal("FAIL OPEN: ReserveProviderEx must still return a candidate when every provider is breaker-open")
	}
	selected.RemovePending("r2")

	// A success closes the breaker and restores normal (non-fail-open) routing.
	reg.RecordProviderOutcome(good.ID, true, 200, "")
	if reg.ProviderBreakerOpen(good.ID) {
		t.Fatal("a success must close the good provider's breaker")
	}
	selected, decision = reg.ReserveProviderEx(model, req("r3"))
	if selected == nil || selected.ID != good.ID {
		t.Fatalf("after recovery the healthy provider must serve again, got %v", selected)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1 (bad still quarantined, good recovered)", decision.CandidateCount)
	}
}

// TestReservationCommitRevalidatesBreakerFailOpen proves a stale fail-open scan
// cannot commit a breaker-open provider after a healthy route recovers. The
// normal-breaker pass is repeated inside the serialized commit before the bypass
// is honored.
func TestReservationCommitRevalidatesBreakerFailOpen(t *testing.T) {
	reg := New(testLogger())
	model := "breaker-commit-revalidate"
	bad := makeSchedulerProvider(t, reg, "bad", model, 200)
	good := makeSchedulerProvider(t, reg, "good", model, 50)
	good.mu.Lock()
	good.Status = StatusUntrusted
	good.mu.Unlock()
	for range providerBreakerConsecTrip {
		reg.RecordProviderOutcome(bad.ID, false, 503, "internal error")
	}

	scanned := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	reg.reservationAfterScan = func(string) {
		once.Do(func() {
			close(scanned)
			<-release
		})
	}
	selected := make(chan *Provider, 1)
	go func() {
		p, _ := reg.ReserveProviderEx(model, &PendingRequest{
			RequestID: "breaker-commit", Model: model, RequestedMaxTokens: 128,
		})
		selected <- p
	}()
	<-scanned
	good.mu.Lock()
	good.Status = StatusOnline
	good.mu.Unlock()
	close(release)

	winner := <-selected
	if winner == nil || winner.ID != good.ID {
		t.Fatalf("winner=%v, want newly healthy provider %q instead of stale fail-open %q", winner, good.ID, bad.ID)
	}
	winner.RemovePending("breaker-commit")
}

// The PUBLIC PREFLIGHT (QuickCapacityCheck) must fail open on the node-health
// breaker: the breaker is a selection-time gate with a fail-open valve in the
// dispatch path, so if the preflight excluded breaker-open nodes an
// all-breaker-open fleet would report 0 candidates / 0 capacity-rejections and
// the consumer would hard-503 "no_provider" BEFORE dispatch's fail-open ran —
// defeating the valve during a bad fleet-wide rollout. The preflight therefore
// ignores the provider breaker (every other gate, incl. the shape-keyed
// inference-error cooldown, is still honored at the preflight).
func TestQuickCapacityCheckFailsOpenOnProviderBreaker(t *testing.T) {
	reg := New(testLogger())
	model := "preflight-failopen-model"
	p := makeSchedulerProvider(t, reg, "solo", model, 100)

	// A healthy provider is a preflight candidate.
	if cc, _, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); cc != 1 {
		t.Fatalf("healthy provider: candidateCount=%d, want 1", cc)
	}

	// Trip the only provider's breaker — the entire fleet is now breaker-open.
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 503, "internal error")
	}
	if !reg.ProviderBreakerOpen(p.ID) {
		t.Fatal("provider breaker must be open")
	}
	// Selection-time gate still excludes it (honored at dispatch)...
	if !providerBreakerOpenAt(reg, p.ID, time.Now()) {
		t.Fatal("selection gate must report the breaker open")
	}
	// ...but the PREFLIGHT must still count it as a candidate so the consumer
	// path falls through to dispatch's fail-open valve instead of a hard 503.
	if cc, capRej, _ := reg.QuickCapacityCheck(model, 100, 128, RequestTraits{}); cc != 1 {
		t.Fatalf("FAIL OPEN: preflight candidateCount=%d (capacityRejections=%d), want 1 (breaker ignored in preflight)", cc, capRej)
	}
}

// Disconnect must drop an identity-less session's breaker state (its gate was
// keyed by the session UUID, which never recurs) so it leaves no residue.
func TestDisconnectClearsProviderBreaker(t *testing.T) {
	reg := New(testLogger())
	model := "disconnect-breaker-model"
	p := makeSchedulerProvider(t, reg, "victim", model, 100)
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 500, "")
	}
	s := reg.faults.StatusForKey(p.ID, "", "")
	hasWin, hasOpen, hasTrips := s.BreakerPresent, !s.BreakerUntil.IsZero(), s.BreakerTrips > 0
	if !hasWin || !hasOpen || !hasTrips {
		t.Fatalf("expected breaker state before disconnect: win=%v open=%v trips=%v", hasWin, hasOpen, hasTrips)
	}

	reg.Disconnect(p.ID)

	if g := rawGateForKey(reg, p.ID); g != nil {
		t.Fatalf("Disconnect must drop the session-keyed gate, got %+v", g)
	}
	if reg.ProviderBreakerOpen(p.ID) {
		t.Fatal("Disconnect must drop all breaker state")
	}
}

// The periodic gate sweep (gate_state.go) must bound the index by dropping
// identities whose breaker has expired and whose ring has aged out, once no
// live session references them.
func TestProviderBreakerMapsBounded(t *testing.T) {
	r := New(testLogger())
	for i := 0; i < 1100; i++ {
		id := fmt.Sprintf("dead-%d", i)
		for j := 0; j < providerBreakerConsecTrip; j++ {
			r.RecordProviderOutcome(id, false, 500, "")
		}
	}
	if n := r.gateCount(); n < 1000 {
		t.Fatalf("setup produced too few distinct gates: %d", n)
	}

	// Past the breaker cooldown, the ring window and the idle grace, every
	// dead identity is idle. A connected provider's gate stays regardless.
	live := makeSchedulerProvider(t, r, "live", "m", 50)
	r.RecordProviderOutcome(live.ID, false, 500, "")
	r.sweepGates(time.Now().Add(gateIdleGrace + providerBreakerMaxCooldown + time.Second))

	if after := r.gateCount(); after != 1 {
		t.Fatalf("sweep should leave only the live provider's gate, got %d", after)
	}
	winAfter := 0
	if providerHealthWindowOf(r, live.ID) != nil {
		winAfter = 1
	}
	if winAfter != 1 {
		t.Fatalf("stale-window sweep should leave only the live entry, got %d", winAfter)
	}
}

// --- providerHealthWindow.merge (fault-state migration onto a populated key) ---
