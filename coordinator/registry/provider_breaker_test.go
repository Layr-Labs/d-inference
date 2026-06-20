package registry

import (
	"fmt"
	"testing"
	"time"
)

// --- test helpers (poke internal maps / call *Locked helpers, mirroring
// error_cooldown_test.go) ---

func providerBreakerOpenAt(r *Registry, id string, now time.Time) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providerBreakerOpenLocked(id, now)
}

func providerBreakerTripsOf(r *Registry, id string) int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providerBreakerTrips[id]
}

func providerBreakerOpenUntilOf(r *Registry, id string) time.Time {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providerBreakerOpenUntil[id]
}

// expireProviderBreaker rewinds a provider's open expiry into the past,
// simulating the cooldown elapsing (open -> half-open) without sleeping.
func expireProviderBreaker(r *Registry, id string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.providerBreakerOpenUntil[id] = time.Now().Add(-time.Second)
}

// seedProviderHealthWindow records a fixed sequence of outcomes (true=success,
// false=fault) directly into a provider's ring WITHOUT running the trip logic,
// so a test can construct a window state (e.g. a sustained high fault rate with
// a low consecutive-fault counter) that monotonic RecordProviderOutcome calls
// could not reach before the consecutive-fault path fires.
func seedProviderHealthWindow(r *Registry, id string, pattern []bool, now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	w := r.providerHealthWindowLocked(id)
	for _, ok := range pattern {
		w.record(ok, now)
	}
}

// --- classifier unit tests ---

func TestProviderOutcomeIsFault(t *testing.T) {
	cases := []struct {
		code  int
		err   string
		fault bool
	}{
		// Client-shape sheds: never the provider's fault.
		{429, "rate limited", false},
		{400, "bad request", false},
		{404, "not found", false},
		{422, "unprocessable", false},
		{499, "client closed request", false},
		{418, "teapot", false},
		// Provider-sickness status codes count when the message is not capacity.
		{500, "internal server error", true},
		{502, "bad gateway", true},
		{504, "", true},
		// ...but a capacity/backpressure message makes a 500/502/504 a healthy
		// shed too: some (and older) provider paths surface capacity rejects as a
		// non-503 5xx, and the dispatch reclassifier turns those into uptime-
		// neutral 429s, so the node breaker must not count them as faults.
		{500, "token_budget_exhausted: request requires 9000 tokens", false},
		{502, "insufficient global KV cache headroom", false},
		{504, "request timed out waiting for capacity", false},
		// Unattributed non-2xx codes are NOT counted (conservative).
		{501, "not implemented", false},
		{505, "", false},
		{0, "weird", false},
		// Capacity-class 503s: healthy-but-busy, never counted.
		{503, "token_budget exhausted", false},
		{503, "insufficient KV headroom", false},
		{503, "insufficient memory to load model", false},
		{503, "kv cache headroom too low", false},
		{503, "GPU OOM", false},
		{503, "out of memory", false},
		{503, "context length exceeded", false},
		{503, "context window exceeded", false},
		{503, "provider draining for update", false},
		{503, "request timed out waiting for capacity", false},
		{503, "queue full", false},
		{503, "server busy", false},
		{503, "service temporarily unavailable", false},
		{503, "All 3 model slot(s) are active; cannot load 'x'", false},
		// Overload/backpressure shed — healthy-but-busy, consistent with the api
		// reclassifier and the inference-error breaker (NOT a node fault).
		{503, "request rejected", false},
		// "room" must NOT match the whole word "oom".
		{503, "no room left for this request", true},
		// Fault-shaped 503s: genuine node faults, counted.
		{503, "internal error", true},
		{503, "model load failed", true},
		{503, "The operation couldn't be completed. (error 1.)", true},
		// An empty 503 message defaults to fault (no capacity marker present).
		{503, "", true},
	}
	for _, c := range cases {
		if got := providerOutcomeIsFault(c.code, c.err); got != c.fault {
			t.Errorf("providerOutcomeIsFault(%d, %q)=%v, want %v", c.code, c.err, got, c.fault)
		}
	}
}

// --- breaker behavior ---

// A node returning genuine faults for ~all of its requests must be quarantined.
// Five consecutive faults open the breaker.
func TestProviderBreakerConsecutiveTrip(t *testing.T) {
	r := New(testLogger())
	const id = "p1"
	for i := 0; i < providerBreakerConsecTrip-1; i++ {
		opened, closed := r.RecordProviderOutcome(id, false, 500, "")
		if opened || closed {
			t.Fatalf("fault %d: opened=%v closed=%v, want both false before the threshold", i+1, opened, closed)
		}
		if r.ProviderBreakerOpen(id) {
			t.Fatalf("breaker opened early after %d consecutive faults", i+1)
		}
	}
	opened, _ := r.RecordProviderOutcome(id, false, 500, "")
	if !opened {
		t.Fatalf("the %dth consecutive fault must open the breaker", providerBreakerConsecTrip)
	}
	if !r.ProviderBreakerOpen(id) {
		t.Fatal("breaker must report open after the trip")
	}
	// A further fault while OPEN must not report a new transition.
	if opened, _ := r.RecordProviderOutcome(id, false, 500, ""); opened {
		t.Fatal("a fault while already open must not report a new transition")
	}
}

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
	honored := reg.providerPassesRoutingGatesLockedEx(p, model, RequestTraits{}, false, now, false)
	bypassed := reg.providerPassesRoutingGatesLockedEx(p, model, RequestTraits{}, false, now, true)
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

// The sustained fail-RATE path (>=20 outcomes, >80% faults) trips even when the
// consecutive-fault counter is low; exactly 80% stays closed.
func TestProviderBreakerRateTrip(t *testing.T) {
	t.Run("above 80% trips", func(t *testing.T) {
		r := New(testLogger())
		const id = "p-rate-hot"
		now := time.Now()
		// 17 faults + 3 trailing successes => 85% fault, consec=0. The window is
		// full (20) but no 5-consecutive-fault run, so only the rate path can fire.
		pattern := make([]bool, 0, providerHealthRingSize)
		for i := 0; i < 17; i++ {
			pattern = append(pattern, false)
		}
		for i := 0; i < 3; i++ {
			pattern = append(pattern, true)
		}
		seedProviderHealthWindow(r, id, pattern, now)
		opened, _ := r.RecordProviderOutcome(id, false, 503, "internal error")
		if !opened {
			t.Fatal("a sustained >80% fault rate over a full window must open the breaker")
		}
	})

	t.Run("exactly 80% stays closed", func(t *testing.T) {
		r := New(testLogger())
		const id = "p-rate-edge"
		now := time.Now()
		// 16 faults + 4 trailing successes => exactly 80% (not > 80%), consec=0.
		pattern := make([]bool, 0, providerHealthRingSize)
		for i := 0; i < 16; i++ {
			pattern = append(pattern, false)
		}
		for i := 0; i < 4; i++ {
			pattern = append(pattern, true)
		}
		seedProviderHealthWindow(r, id, pattern, now)
		opened, _ := r.RecordProviderOutcome(id, false, 503, "internal error")
		if opened {
			t.Fatal("exactly 80% fault rate must NOT open the breaker (threshold is strictly greater)")
		}
		if r.ProviderBreakerOpen(id) {
			t.Fatal("breaker must stay closed at exactly the 80% boundary")
		}
	})
}

// Half-open lifecycle: after the cooldown elapses the gate allows a probe; a
// success closes the breaker and resets the backoff; a fault re-arms it with a
// larger (exponential) cooldown.
func TestProviderBreakerHalfOpenRecoveryAndReArm(t *testing.T) {
	r := New(testLogger())
	const id = "p-half"

	for i := 0; i < providerBreakerConsecTrip; i++ {
		r.RecordProviderOutcome(id, false, 500, "")
	}
	if !r.ProviderBreakerOpen(id) {
		t.Fatal("breaker must be open after the consecutive-fault trip")
	}
	if got := providerBreakerTripsOf(r, id); got != 1 {
		t.Fatalf("trips=%d after first trip, want 1", got)
	}
	// OPEN: the gate rejects (no probe yet).
	if !providerBreakerOpenAt(r, id, time.Now()) {
		t.Fatal("gate must report open during the cooldown")
	}

	// Cooldown elapses => half-open: the gate must allow a probe.
	expireProviderBreaker(r, id)
	if providerBreakerOpenAt(r, id, time.Now()) {
		t.Fatal("once the cooldown elapses the gate must allow a half-open probe")
	}

	// A FAULT during half-open re-arms with a larger backoff.
	beforeReArm := time.Now()
	opened, _ := r.RecordProviderOutcome(id, false, 503, "internal error")
	if !opened {
		t.Fatal("a fault during half-open must re-open (re-arm) the breaker")
	}
	if got := providerBreakerTripsOf(r, id); got != 2 {
		t.Fatalf("trips=%d after re-arm, want 2", got)
	}
	remaining := providerBreakerOpenUntilOf(r, id).Sub(beforeReArm)
	if remaining < providerBreakerBaseCooldown+30*time.Second {
		t.Fatalf("re-arm cooldown %v must exceed the base %v (exponential backoff)", remaining, providerBreakerBaseCooldown)
	}

	// Cooldown elapses again => half-open => a SUCCESS closes and resets.
	expireProviderBreaker(r, id)
	_, closed := r.RecordProviderOutcome(id, true, 200, "")
	if !closed {
		t.Fatal("a success during half-open must close the breaker")
	}
	if r.ProviderBreakerOpen(id) {
		t.Fatal("breaker must be closed after a successful probe")
	}
	if got := providerBreakerTripsOf(r, id); got != 0 {
		t.Fatalf("trips=%d after close, want 0 (backoff reset)", got)
	}
	// Recovery reset the consecutive counter: one fresh fault must not re-open.
	if opened, _ := r.RecordProviderOutcome(id, false, 500, ""); opened {
		t.Fatal("a single fault after recovery must not immediately re-open the breaker")
	}
}

// A success while the breaker is still OPEN (an in-flight request that beat the
// quarantine) closes it immediately — auto-re-admit on proven recovery.
func TestProviderBreakerSuccessWhileOpenCloses(t *testing.T) {
	r := New(testLogger())
	const id = "p-inflight"
	for i := 0; i < providerBreakerConsecTrip; i++ {
		r.RecordProviderOutcome(id, false, 500, "")
	}
	if !r.ProviderBreakerOpen(id) {
		t.Fatal("breaker must be open")
	}
	_, closed := r.RecordProviderOutcome(id, true, 200, "")
	if !closed {
		t.Fatal("a success while open must close the breaker")
	}
	if r.ProviderBreakerOpen(id) {
		t.Fatal("breaker must be closed after the in-flight success")
	}
}

// Healthy sheds (client-shape 4xx/429 and capacity-class 503) must NEVER trip
// the breaker, even in large volume — load alone cannot quarantine a node.
func TestProviderBreakerIgnoresHealthySheds(t *testing.T) {
	r := New(testLogger())
	const id = "p-busy"
	sheds := []struct {
		code int
		err  string
	}{
		{429, "rate limited"},
		{400, "bad request"},
		{404, "not found"},
		{499, "client closed request"},
		// Capacity-shaped non-503 5xx (older/provider paths) — still healthy sheds.
		{500, "token_budget_exhausted"},
		{502, "insufficient KV headroom"},
		{504, "request timed out waiting for capacity"},
		{503, "token_budget exhausted"},
		{503, "insufficient KV headroom"},
		{503, "insufficient memory to load model"},
		{503, "GPU OOM"},
		{503, "out of memory"},
		{503, "context length exceeded"},
		{503, "context window exceeded"},
		{503, "provider draining for update"},
		{503, "request timed out waiting for capacity"},
		{503, "queue full"},
		{503, "server busy"},
		{503, "service temporarily unavailable"},
		{503, "request rejected"},
		{503, "All 3 model slot(s) are active; cannot load 'x'"},
	}
	for i := 0; i < 100; i++ {
		s := sheds[i%len(sheds)]
		if opened, _ := r.RecordProviderOutcome(id, false, s.code, s.err); opened {
			t.Fatalf("healthy shed #%d (%d %q) must never open the breaker", i, s.code, s.err)
		}
	}
	if r.ProviderBreakerOpen(id) {
		t.Fatal("100 healthy sheds must not quarantine a provider")
	}
	// Healthy sheds are ignored entirely — no health window is even created.
	r.mu.RLock()
	w := r.providerOutcomes[id]
	r.mu.RUnlock()
	if w != nil {
		t.Fatalf("healthy sheds must not record into the health ring, got %+v", w)
	}
}

// Each genuine-fault flavor (fault-503 variants and 500/502/504) must trip the
// breaker after the consecutive threshold.
func TestProviderBreakerFaultFlavorsTrip(t *testing.T) {
	faults := []struct {
		name string
		code int
		err  string
	}{
		{"internal error 503", 503, "internal error"},
		{"model load failed 503", 503, "model load failed"},
		{"opaque Foundation 503", 503, "The operation couldn't be completed. (error 1.)"},
		{"empty 503 defaults to fault", 503, ""},
		{"500", 500, "internal server error"},
		{"502", 502, "bad gateway"},
		{"504 silent", 504, ""},
	}
	for _, f := range faults {
		t.Run(f.name, func(t *testing.T) {
			r := New(testLogger())
			const id = "p-fault"
			var opened bool
			for i := 0; i < providerBreakerConsecTrip; i++ {
				opened, _ = r.RecordProviderOutcome(id, false, f.code, f.err)
			}
			if !opened {
				t.Fatalf("%d consecutive %q faults must open the breaker", providerBreakerConsecTrip, f.name)
			}
			if !r.ProviderBreakerOpen(id) {
				t.Fatalf("%s: breaker must be open", f.name)
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

// Disconnect must drop every per-provider breaker map entry so a per-session
// UUID leaves no residue.
func TestDisconnectClearsProviderBreaker(t *testing.T) {
	reg := New(testLogger())
	model := "disconnect-breaker-model"
	p := makeSchedulerProvider(t, reg, "victim", model, 100)
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 500, "")
	}
	reg.mu.RLock()
	_, hasWin := reg.providerOutcomes[p.ID]
	_, hasOpen := reg.providerBreakerOpenUntil[p.ID]
	_, hasTrips := reg.providerBreakerTrips[p.ID]
	reg.mu.RUnlock()
	if !hasWin || !hasOpen || !hasTrips {
		t.Fatalf("expected breaker state before disconnect: win=%v open=%v trips=%v", hasWin, hasOpen, hasTrips)
	}

	reg.Disconnect(p.ID)

	reg.mu.RLock()
	_, hasWin = reg.providerOutcomes[p.ID]
	_, hasOpen = reg.providerBreakerOpenUntil[p.ID]
	_, hasTrips = reg.providerBreakerTrips[p.ID]
	reg.mu.RUnlock()
	if hasWin || hasOpen || hasTrips {
		t.Fatalf("Disconnect must drop all breaker state: win=%v open=%v trips=%v", hasWin, hasOpen, hasTrips)
	}
}

// The opportunistic >1024 sweep (mirroring error_cooldown.go) must bound the
// breaker maps by dropping expired/idle entries.
func TestProviderBreakerMapsBounded(t *testing.T) {
	r := New(testLogger())
	for i := 0; i < 1100; i++ {
		id := fmt.Sprintf("dead-%d", i)
		for j := 0; j < providerBreakerConsecTrip; j++ {
			r.RecordProviderOutcome(id, false, 500, "")
		}
	}
	r.mu.Lock()
	for id := range r.providerBreakerOpenUntil {
		r.providerBreakerOpenUntil[id] = time.Now().Add(-time.Second)
	}
	for _, w := range r.providerOutcomes {
		for i := range w.outcomes {
			if !w.outcomes[i].ts.IsZero() {
				w.outcomes[i].ts = w.outcomes[i].ts.Add(-(providerBreakerWindow + time.Second))
			}
		}
	}
	openCount := len(r.providerBreakerOpenUntil)
	winCount := len(r.providerOutcomes)
	r.mu.Unlock()
	if openCount < 1000 || winCount < 1000 {
		t.Fatalf("setup produced too few distinct entries: open=%d win=%d", openCount, winCount)
	}

	// A live record triggers the >1024 sweep before recording.
	r.RecordProviderOutcome("live", false, 500, "")

	r.mu.RLock()
	openAfter := len(r.providerBreakerOpenUntil)
	tripsAfter := len(r.providerBreakerTrips)
	winAfter := len(r.providerOutcomes)
	r.mu.RUnlock()
	if openAfter != 0 {
		t.Fatalf("expired-breaker sweep should drop every entry (live pair has no open breaker yet), got %d", openAfter)
	}
	if tripsAfter != 0 {
		t.Fatalf("trip counts must be swept alongside expired breakers, got %d", tripsAfter)
	}
	if winAfter != 1 {
		t.Fatalf("stale-window sweep should leave only the live entry, got %d", winAfter)
	}
}
