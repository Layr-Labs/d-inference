package registry_test

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

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
		if got := identitygate.ProviderOutcomeIsFault(c.code, c.err); got != c.fault {
			t.Errorf("providerOutcomeIsFault(%d, %q)=%v, want %v", c.code, c.err, got, c.fault)
		}
	}
}

// A node returning genuine faults for ~all of its requests must be quarantined.
// Five consecutive faults open the breaker.
func TestProviderBreakerConsecutiveTrip(t *testing.T) {
	r := production.New(testLogger())
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

// The gate must structurally exclude a breaker-open provider, and the fail-open
// bypass must let it back in.
func TestProviderPassesRoutingGatesBreakerBypass(t *testing.T) {
	reg, gates, _ := newFaultGateFixture()
	model := "gate-bypass-model"
	p := makeSchedulerProvider(t, reg, "p", model, 100)
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 500, "")
	}
	now := time.Now()
	view := gates.ViewReference(gates.ResolveSession(p.ID, false))
	p.Mu().Lock()
	honored := view.Evaluate(model, production.RequestTraits{}.CooldownShape(), nil, now, false, false).Reason == identitygate.Allowed
	bypassed := view.Evaluate(model, production.RequestTraits{}.CooldownShape(), nil, now, true, false).Reason == identitygate.Allowed
	p.Mu().Unlock()
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
			if got := selection.BypassBreaker(c.winner, c.breakerRejected, c.capacity, c.ttft); got != c.want {
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
		r, gates, clock := newFaultGateFixture()
		const id = "p-rate-hot"
		now := clock.Now()
		// 17 faults + 3 trailing successes => 85% fault, consec=0. Successes
		// clear the intermediate trip, retaining all 20 outcomes at now; the
		// next fault can therefore trip only the rate path.
		pattern := make([]bool, 0, identitygate.HealthRingSize)
		for i := 0; i < 17; i++ {
			pattern = append(pattern, false)
		}
		for i := 0; i < 3; i++ {
			pattern = append(pattern, true)
		}
		seedProviderHealthWindow(r, id, pattern)
		health := gates.ViewForSession(nil, id).BreakerHealth(now)
		if !health.HasHistory || health.Samples != 20 || health.Failures != 17 || health.ConsecutiveFaults != 0 || health.Trips != 0 || !health.RetryAfter.IsZero() {
			t.Fatalf("seeded rate history must retain 17 faults/3 successes with no streak and reset trip state, got %+v", health)
		}
		if providerBreakerOpenAt(gates, id, now) {
			t.Fatal("seeded rate history must leave the breaker closed before the target fault")
		}
		opened, _ := r.RecordProviderOutcome(id, false, 503, "internal error")
		if !opened {
			t.Fatal("a sustained >80% fault rate over a full window must open the breaker")
		}
	})

	t.Run("exactly 80% stays closed", func(t *testing.T) {
		r, gates, clock := newFaultGateFixture()
		const id = "p-rate-edge"
		now := clock.Now()
		// 16 faults + 4 trailing successes => exactly 80% (not > 80%), consec=0.
		// Successes clear the intermediate trip while retaining the full history.
		pattern := make([]bool, 0, identitygate.HealthRingSize)
		for i := 0; i < 16; i++ {
			pattern = append(pattern, false)
		}
		for i := 0; i < 4; i++ {
			pattern = append(pattern, true)
		}
		seedProviderHealthWindow(r, id, pattern)
		health := gates.ViewForSession(nil, id).BreakerHealth(now)
		if !health.HasHistory || health.Samples != 20 || health.Failures != 16 || health.ConsecutiveFaults != 0 || health.Trips != 0 || !health.RetryAfter.IsZero() {
			t.Fatalf("seeded rate history must retain 16 faults/4 successes with no streak and reset trip state, got %+v", health)
		}
		if providerBreakerOpenAt(gates, id, now) {
			t.Fatal("seeded rate history must leave the breaker closed before the target fault")
		}
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
	r, gates, clock := newFaultGateFixture()
	const id = "p-half"

	for i := 0; i < providerBreakerConsecTrip; i++ {
		r.RecordProviderOutcome(id, false, 500, "")
	}
	if !r.ProviderBreakerOpen(id) {
		t.Fatal("breaker must be open after the consecutive-fault trip")
	}
	if got := gates.ViewForSession(nil, id).BreakerHealth(clock.Now()).Trips; got != 1 {
		t.Fatalf("trips=%d after first trip, want 1", got)
	}
	// OPEN: the gate rejects (no probe yet).
	if !providerBreakerOpenAt(gates, id, clock.Now()) {
		t.Fatal("gate must report open during the cooldown")
	}

	// Cooldown elapses => half-open: the gate must allow a probe.
	clock.Set(gates.ViewForSession(nil, id).BreakerHealth(clock.Now()).RetryAfter.Add(time.Second))
	if providerBreakerOpenAt(gates, id, clock.Now()) {
		t.Fatal("once the cooldown elapses the gate must allow a half-open probe")
	}

	// A FAULT during half-open re-arms with a larger backoff.
	beforeReArm := clock.Now()
	opened, _ := r.RecordProviderOutcome(id, false, 503, "internal error")
	if !opened {
		t.Fatal("a fault during half-open must re-open (re-arm) the breaker")
	}
	if got := gates.ViewForSession(nil, id).BreakerHealth(clock.Now()).Trips; got != 2 {
		t.Fatalf("trips=%d after re-arm, want 2", got)
	}
	remaining := gates.ViewForSession(nil, id).BreakerHealth(clock.Now()).RetryAfter.Sub(beforeReArm)
	if remaining < providerBreakerBaseCooldown+30*time.Second {
		t.Fatalf("re-arm cooldown %v must exceed the base %v (exponential backoff)", remaining, providerBreakerBaseCooldown)
	}

	// Cooldown elapses again => half-open => a SUCCESS closes and resets.
	clock.Set(gates.ViewForSession(nil, id).BreakerHealth(clock.Now()).RetryAfter.Add(time.Second))
	_, closed := r.RecordProviderOutcome(id, true, 200, "")
	if !closed {
		t.Fatal("a success during half-open must close the breaker")
	}
	if r.ProviderBreakerOpen(id) {
		t.Fatal("breaker must be closed after a successful probe")
	}
	if got := gates.ViewForSession(nil, id).BreakerHealth(clock.Now()).Trips; got != 0 {
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
	r := production.New(testLogger())
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
	r, gates, clock := newFaultGateFixture()
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
	if w := gates.ViewForSession(nil, id).BreakerHealth(clock.Now()); w.HasHistory {
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
			r := production.New(testLogger())
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
	reg := production.New(testLogger())
	model := "node-health-model"
	bad := makeSchedulerProvider(t, reg, "bad", model, 200)  // faster: normally preferred
	good := makeSchedulerProvider(t, reg, "good", model, 50) // slower

	req := func(id string) *production.PendingRequest {
		return &production.PendingRequest{RequestID: id, Model: model, RequestedMaxTokens: 128}
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
	reg, preparation := newReservationFixture()
	model := "breaker-commit-revalidate"
	bad := makeSchedulerProvider(t, reg, "bad", model, 200)
	good := makeSchedulerProvider(t, reg, "good", model, 50)
	good.Mu().Lock()
	good.Status = production.StatusUntrusted
	good.Mu().Unlock()
	for range providerBreakerConsecTrip {
		reg.RecordProviderOutcome(bad.ID, false, 503, "internal error")
	}

	scanned := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	preparation.after = func(string) {
		once.Do(func() {
			close(scanned)
			<-release
		})
	}
	selected := make(chan *production.Provider, 1)
	go func() {
		p, _ := reg.ReserveProviderEx(model, &production.PendingRequest{
			RequestID: "breaker-commit", Model: model, RequestedMaxTokens: 128,
		})
		selected <- p
	}()
	<-scanned
	good.Mu().Lock()
	good.Status = production.StatusOnline
	good.Mu().Unlock()
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
	reg, gates, _ := newFaultGateFixture()
	model := "preflight-failopen-model"
	p := makeSchedulerProvider(t, reg, "solo", model, 100)

	// A healthy provider is a preflight candidate.
	if cc, _, _ := reg.QuickCapacityCheck(model, 100, 128, production.RequestTraits{}); cc != 1 {
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
	if !providerBreakerOpenAt(gates, p.ID, time.Now()) {
		t.Fatal("selection gate must report the breaker open")
	}
	// ...but the PREFLIGHT must still count it as a candidate so the consumer
	// path falls through to dispatch's fail-open valve instead of a hard 503.
	if cc, capRej, _ := reg.QuickCapacityCheck(model, 100, 128, production.RequestTraits{}); cc != 1 {
		t.Fatalf("FAIL OPEN: preflight candidateCount=%d (capacityRejections=%d), want 1 (breaker ignored in preflight)", cc, capRej)
	}
}

// Disconnect must drop an identity-less session's breaker state (its gate was
// keyed by the session UUID, which never recurs) so it leaves no residue.
func TestDisconnectClearsProviderBreaker(t *testing.T) {
	reg, gates, clock := newFaultGateFixture()
	model := "disconnect-breaker-model"
	p := makeSchedulerProvider(t, reg, "victim", model, 100)
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 500, "")
	}
	health := gates.ViewIdentity(p.ID).BreakerHealth(clock.Now())
	hasWin, hasOpen, hasTrips := health.HasHistory, !health.RetryAfter.IsZero(), health.Trips > 0
	if !hasWin || !hasOpen || !hasTrips {
		t.Fatalf("expected breaker state before disconnect: win=%v open=%v trips=%v", hasWin, hasOpen, hasTrips)
	}

	reg.Disconnect(p.ID)

	if g := gates.ViewIdentity(p.ID); g.Present() {
		t.Fatalf("Disconnect must drop the session-keyed gate, got %+v", g)
	}
	if reg.ProviderBreakerOpen(p.ID) {
		t.Fatal("Disconnect must drop all breaker state")
	}
}

// The periodic gate sweep must bound the index by dropping identities whose
// breaker has expired and whose ring has aged out, once no live session
// references them.
func TestProviderBreakerMapsBounded(t *testing.T) {
	r, gates, clock := newFaultGateFixture()
	for i := 0; i < 1100; i++ {
		id := fmt.Sprintf("dead-%d", i)
		for j := 0; j < providerBreakerConsecTrip; j++ {
			r.RecordProviderOutcome(id, false, 500, "")
		}
	}
	if n := gates.Sweep(clock.Now()); n < 1000 {
		t.Fatalf("setup produced too few distinct gates: %d", n)
	}

	// Past the breaker cooldown, the ring window and the idle grace, every
	// dead identity is idle. A connected provider's gate stays regardless.
	live := makeSchedulerProvider(t, r, "live", "m", 50)
	r.RecordProviderOutcome(live.ID, false, 500, "")
	clock.Advance(gateIdleGrace + providerBreakerMaxCooldown + time.Second)
	after := gates.Sweep(clock.Now())

	if after != 1 {
		t.Fatalf("sweep should leave only the live provider's gate, got %d", after)
	}
	winAfter := 0
	if gates.ViewForSession(nil, live.ID).BreakerHealth(clock.Now()).HasHistory {
		winAfter = 1
	}
	if winAfter != 1 {
		t.Fatalf("stale-window sweep should leave only the live entry, got %d", winAfter)
	}
}

func TestProviderHealthWindowMerge(t *testing.T) {
	base := time.Now()
	at := func(i int) time.Time { return base.Add(time.Duration(i) * time.Second) }
	fill := func(seq ...identitygate.HealthOutcome) *identitygate.HealthHistory {
		w := &identitygate.HealthHistory{}
		for _, o := range seq {
			w.Record(o.Success, o.At)
		}
		return w
	}

	t.Run("empty source is a no-op", func(t *testing.T) {
		dst := fill(identitygate.HealthOutcome{At: at(0), Success: false}, identitygate.HealthOutcome{At: at(1), Success: false})
		dst.Merge(&identitygate.HealthHistory{})
		dst.Merge(nil)
		if len(dst.Chronological()) != 2 || dst.FaultStreak() != 2 {
			t.Fatalf("size=%d consecFail=%d, want 2/2", len(dst.Chronological()), dst.FaultStreak())
		}
	})

	t.Run("empty destination adopts the source", func(t *testing.T) {
		dst := &identitygate.HealthHistory{}
		dst.Merge(fill(identitygate.HealthOutcome{At: at(0), Success: true}, identitygate.HealthOutcome{At: at(1), Success: false}))
		if len(dst.Chronological()) != 2 || dst.FaultStreak() != 1 {
			t.Fatalf("size=%d consecFail=%d, want 2/1", len(dst.Chronological()), dst.FaultStreak())
		}
	})

	t.Run("interleaved timestamps merge chronologically", func(t *testing.T) {
		dst := fill(identitygate.HealthOutcome{At: at(0), Success: false}, identitygate.HealthOutcome{At: at(2), Success: true}, identitygate.HealthOutcome{At: at(4), Success: false})
		src := fill(identitygate.HealthOutcome{At: at(1), Success: false}, identitygate.HealthOutcome{At: at(3), Success: false}, identitygate.HealthOutcome{At: at(5), Success: false})
		dst.Merge(src)
		if len(dst.Chronological()) != 6 {
			t.Fatalf("size=%d, want 6", len(dst.Chronological()))
		}
		seq := dst.Chronological()
		for i := 1; i < len(seq); i++ {
			if seq[i].At.Before(seq[i-1].At) {
				t.Fatalf("merged entries out of order at %d: %v after %v", i, seq[i].At, seq[i-1].At)
			}
		}
		// Trailing run after the success at t2: faults at t3, t4, t5.
		if dst.FaultStreak() != 3 {
			t.Fatalf("consecFail=%d, want 3 (recomputed from the merged tail)", dst.FaultStreak())
		}
		if total, fails := dst.WindowStats(at(5), identitygate.BreakerWindow); total != 6 || fails != 5 {
			t.Fatalf("windowStats=(%d,%d), want (6,5)", total, fails)
		}
	})

	t.Run("trailing success resets the merged streak", func(t *testing.T) {
		dst := fill(identitygate.HealthOutcome{At: at(0), Success: false}, identitygate.HealthOutcome{At: at(1), Success: false})
		dst.Merge(fill(identitygate.HealthOutcome{At: at(2), Success: true}))
		if dst.FaultStreak() != 0 {
			t.Fatalf("consecFail=%d, want 0 — the newest merged outcome is a success", dst.FaultStreak())
		}
	})

	t.Run("overflow keeps the most recent ring-size entries", func(t *testing.T) {
		dst, src := &identitygate.HealthHistory{}, &identitygate.HealthHistory{}
		for i := 0; i < 15; i++ {
			dst.Record(false, at(i))
			src.Record(false, at(15+i))
		}
		dst.Merge(src)
		if len(dst.Chronological()) != identitygate.HealthRingSize {
			t.Fatalf("size=%d, want %d", len(dst.Chronological()), identitygate.HealthRingSize)
		}
		seq := dst.Chronological()
		if !seq[0].At.Equal(at(30-identitygate.HealthRingSize)) || !seq[len(seq)-1].At.Equal(at(29)) {
			t.Fatalf("merged window must keep the newest %d entries, got [%v..%v]",
				identitygate.HealthRingSize, seq[0].At, seq[len(seq)-1].At)
		}
		if dst.FaultStreak() != identitygate.HealthRingSize {
			t.Fatalf("consecFail=%d, want %d", dst.FaultStreak(), identitygate.HealthRingSize)
		}
		// A post-merge record must overwrite the OLDEST entry (head correctness).
		dst.Record(true, at(30))
		seq = dst.Chronological()
		if !seq[0].At.Equal(at(31-identitygate.HealthRingSize)) || !seq[len(seq)-1].At.Equal(at(30)) {
			t.Fatalf("post-merge record must evict the oldest entry, got [%v..%v]", seq[0].At, seq[len(seq)-1].At)
		}
		if dst.FaultStreak() != 0 {
			t.Fatalf("consecFail=%d after a success, want 0", dst.FaultStreak())
		}
	})
}
