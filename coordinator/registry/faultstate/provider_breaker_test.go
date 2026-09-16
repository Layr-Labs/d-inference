package faultstate

import (
	"testing"
	"time"
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
		if got := providerOutcomeIsFault(c.code, c.err); got != c.fault {
			t.Errorf("providerOutcomeIsFault(%d, %q)=%v, want %v", c.code, c.err, got, c.fault)
		}
	}
}

// A node returning genuine faults for ~all of its requests must be quarantined.
// Five consecutive faults open the breaker.
func TestProviderBreakerConsecutiveTrip(t *testing.T) {
	r := newTestManager(testLogger())
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

// The sustained fail-RATE path (>=20 outcomes, >80% faults) trips even when the
// consecutive-fault counter is low; exactly 80% stays closed.
func TestProviderBreakerRateTrip(t *testing.T) {
	t.Run("above 80% trips", func(t *testing.T) {
		r := newTestManager(testLogger())
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
		r := newTestManager(testLogger())
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
	r := newTestManager(testLogger())
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
	r := newTestManager(testLogger())
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
	r := newTestManager(testLogger())
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
	if w := providerHealthWindowOf(r, id); w != nil {
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
			r := newTestManager(testLogger())
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

func TestProviderHealthWindowMerge(t *testing.T) {
	base := time.Now()
	at := func(i int) time.Time { return base.Add(time.Duration(i) * time.Second) }
	fill := func(seq ...providerHealthOutcome) *providerHealthWindow {
		w := &providerHealthWindow{}
		for _, o := range seq {
			w.record(o.ok, o.ts)
		}
		return w
	}

	t.Run("empty source is a no-op", func(t *testing.T) {
		dst := fill(providerHealthOutcome{ts: at(0), ok: false}, providerHealthOutcome{ts: at(1), ok: false})
		dst.merge(&providerHealthWindow{})
		dst.merge(nil)
		if dst.size != 2 || dst.consecFail != 2 {
			t.Fatalf("size=%d consecFail=%d, want 2/2", dst.size, dst.consecFail)
		}
	})

	t.Run("empty destination adopts the source", func(t *testing.T) {
		dst := &providerHealthWindow{}
		dst.merge(fill(providerHealthOutcome{ts: at(0), ok: true}, providerHealthOutcome{ts: at(1), ok: false}))
		if dst.size != 2 || dst.consecFail != 1 {
			t.Fatalf("size=%d consecFail=%d, want 2/1", dst.size, dst.consecFail)
		}
	})

	t.Run("interleaved timestamps merge chronologically", func(t *testing.T) {
		dst := fill(providerHealthOutcome{ts: at(0), ok: false}, providerHealthOutcome{ts: at(2), ok: true}, providerHealthOutcome{ts: at(4), ok: false})
		src := fill(providerHealthOutcome{ts: at(1), ok: false}, providerHealthOutcome{ts: at(3), ok: false}, providerHealthOutcome{ts: at(5), ok: false})
		dst.merge(src)
		if dst.size != 6 {
			t.Fatalf("size=%d, want 6", dst.size)
		}
		seq := dst.chronological()
		for i := 1; i < len(seq); i++ {
			if seq[i].ts.Before(seq[i-1].ts) {
				t.Fatalf("merged entries out of order at %d: %v after %v", i, seq[i].ts, seq[i-1].ts)
			}
		}
		// Trailing run after the success at t2: faults at t3, t4, t5.
		if dst.consecFail != 3 {
			t.Fatalf("consecFail=%d, want 3 (recomputed from the merged tail)", dst.consecFail)
		}
		if total, fails := dst.windowStats(at(5), providerBreakerWindow); total != 6 || fails != 5 {
			t.Fatalf("windowStats=(%d,%d), want (6,5)", total, fails)
		}
	})

	t.Run("trailing success resets the merged streak", func(t *testing.T) {
		dst := fill(providerHealthOutcome{ts: at(0), ok: false}, providerHealthOutcome{ts: at(1), ok: false})
		dst.merge(fill(providerHealthOutcome{ts: at(2), ok: true}))
		if dst.consecFail != 0 {
			t.Fatalf("consecFail=%d, want 0 — the newest merged outcome is a success", dst.consecFail)
		}
	})

	t.Run("overflow keeps the most recent ring-size entries", func(t *testing.T) {
		dst, src := &providerHealthWindow{}, &providerHealthWindow{}
		for i := 0; i < 15; i++ {
			dst.record(false, at(i))
			src.record(false, at(15+i))
		}
		dst.merge(src)
		if dst.size != providerHealthRingSize {
			t.Fatalf("size=%d, want %d", dst.size, providerHealthRingSize)
		}
		seq := dst.chronological()
		if !seq[0].ts.Equal(at(30-providerHealthRingSize)) || !seq[len(seq)-1].ts.Equal(at(29)) {
			t.Fatalf("merged window must keep the newest %d entries, got [%v..%v]",
				providerHealthRingSize, seq[0].ts, seq[len(seq)-1].ts)
		}
		if dst.consecFail != providerHealthRingSize {
			t.Fatalf("consecFail=%d, want %d", dst.consecFail, providerHealthRingSize)
		}
		// A post-merge record must overwrite the OLDEST entry (head correctness).
		dst.record(true, at(30))
		seq = dst.chronological()
		if !seq[0].ts.Equal(at(31-providerHealthRingSize)) || !seq[len(seq)-1].ts.Equal(at(30)) {
			t.Fatalf("post-merge record must evict the oldest entry, got [%v..%v]", seq[0].ts, seq[len(seq)-1].ts)
		}
		if dst.consecFail != 0 {
			t.Fatalf("consecFail=%d after a success, want 0", dst.consecFail)
		}
	})
}

func providerBreakerOpenAt(r *testManager, id string, now time.Time) bool {
	return r.breakerOpen(id, now)
}

func providerBreakerTripsOf(r *testManager, id string) (trips int) {
	readGateForSession(r, id, func(g *gateState) {
		if g != nil {
			trips = g.breakerTrips
		}
	})
	return trips
}

func providerBreakerOpenUntilOf(r *testManager, id string) (until time.Time) {
	readGateForSession(r, id, func(g *gateState) {
		if g != nil {
			until = g.breakerUntil
		}
	})
	return until
}

// expireProviderBreaker rewinds a provider's open expiry into the past,
// simulating the cooldown elapsing (open -> half-open) without sleeping.
func expireProviderBreaker(r *testManager, id string) {
	withGateForSession(r, id, func(g *gateState) { g.breakerUntil = time.Now().Add(-time.Second) })
}

// providerHealthWindowOf returns the provider's node-health ring (nil when no
// fault or success was ever recorded).
func providerHealthWindowOf(r *testManager, id string) (w *providerHealthWindow) {
	readGateForSession(r, id, func(g *gateState) {
		if g != nil {
			w = g.outcomes
		}
	})
	return w
}

// seedProviderHealthWindow records a fixed sequence of outcomes (true=success,
// false=fault) directly into a provider's ring WITHOUT running the trip logic,
// so a test can construct a window state (e.g. a sustained high fault rate with
// a low consecutive-fault counter) that monotonic RecordProviderOutcome calls
// could not reach before the consecutive-fault path fires.
func seedProviderHealthWindow(r *testManager, id string, pattern []bool, now time.Time) {
	withGateForSession(r, id, func(g *gateState) {
		w := g.healthWindowLocked()
		for _, ok := range pattern {
			w.record(ok, now)
		}
	})
}
