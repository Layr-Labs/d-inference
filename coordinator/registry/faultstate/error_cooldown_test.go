package faultstate

import (
	"testing"
	"time"
)

// Regression for the prod incident: a deterministic provider-side failure
// (chat-template render crash → 5xx on every tool-bearing request) kept the
// pair routable, so every retry burned on equally-broken providers. The
// breaker must trip on repeated 5xx — and ONLY 5xx: 4xx are client-shape
// errors that must never quarantine a healthy provider.
func TestRecordInferenceErrorThresholdAndErrorClasses(t *testing.T) {
	tests := []struct {
		name        string
		statusCodes []int
		wantEntered []bool // expected return per call, in order
		wantActive  bool   // cooldown state after all calls
	}{
		{
			name:        "single 5xx does not trip",
			statusCodes: []int{500},
			wantEntered: []bool{false},
			wantActive:  false,
		},
		{
			name:        "second 5xx within window trips exactly once",
			statusCodes: []int{500, 500},
			wantEntered: []bool{false, true},
			wantActive:  true,
		},
		{
			name:        "further 5xx while cooling reports no new transition",
			statusCodes: []int{502, 500, 504, 500},
			wantEntered: []bool{false, true, false, false},
			wantActive:  true,
		},
		{
			name:        "4xx never counts",
			statusCodes: []int{400, 404, 422, 429, 499},
			wantEntered: []bool{false, false, false, false, false},
			wantActive:  false,
		},
		{
			// 503 is the provider's capacity/lifecycle signal
			// (tokenBudgetExhausted / requestRejected / update drain) — a
			// healthy-but-busy provider. Counting it would quarantine
			// providers exactly when the fleet is under load.
			name:        "503 never strikes even x10",
			statusCodes: []int{503, 503, 503, 503, 503, 503, 503, 503, 503, 503},
			wantEntered: []bool{false, false, false, false, false, false, false, false, false, false},
			wantActive:  false,
		},
		{
			name:        "504 (accepted then silent) strikes and trips",
			statusCodes: []int{504, 504},
			wantEntered: []bool{false, true},
			wantActive:  true,
		},
		{
			name:        "502 (disconnect flush) strikes and trips",
			statusCodes: []int{502, 502},
			wantEntered: []bool{false, true},
			wantActive:  true,
		},
		{
			name:        "503 noise between real strikes adds nothing but does not mask them",
			statusCodes: []int{500, 503, 503, 504},
			wantEntered: []bool{false, false, false, true},
			wantActive:  true,
		},
		{
			name:        "unattributed 5xx (501/505/507) never counts",
			statusCodes: []int{501, 505, 507, 501, 505},
			wantEntered: []bool{false, false, false, false, false},
			wantActive:  false,
		},
		{
			name:        "4xx between 5xx adds no strikes",
			statusCodes: []int{500, 429, 400, 404},
			wantEntered: []bool{false, false, false, false},
			wantActive:  false,
		},
		{
			name:        "4xx noise does not stop two real 5xx from tripping",
			statusCodes: []int{404, 500, 429, 500},
			wantEntered: []bool{false, false, false, true},
			wantActive:  true,
		},
		{
			name:        "boundary: 500 counts, 499 does not",
			statusCodes: []int{499, 500, 499, 500},
			wantEntered: []bool{false, false, false, true},
			wantActive:  true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			r := newTestManager(testLogger())
			for i, code := range tc.statusCodes {
				got := r.RecordInferenceError("p1", "m1", code, "base")
				if got != tc.wantEntered[i] {
					t.Fatalf("call %d (status %d): enteredCooldown=%v, want %v", i, code, got, tc.wantEntered[i])
				}
			}
			if got := r.InferenceErrorCooldownActive("p1", "m1", "base"); got != tc.wantActive {
				t.Fatalf("InferenceErrorCooldownActive=%v, want %v", got, tc.wantActive)
			}
		})
	}
}

func TestRecordInferenceErrorSlidingWindow(t *testing.T) {
	r := newTestManager(testLogger())
	if r.RecordInferenceError("p1", "m1", 500, "base") {
		t.Fatal("first error must not trip the breaker")
	}
	// Age the first strike past the window: the next error stands alone.
	ageInferenceStrikes(r, "p1", "m1", "base", inferenceErrorWindow+time.Second)
	if r.RecordInferenceError("p1", "m1", 500, "base") {
		t.Fatal("a strike outside the sliding window must not count toward the threshold")
	}
	if r.InferenceErrorCooldownActive("p1", "m1", "base") {
		t.Fatal("cooldown must not be active after the window slid past the first strike")
	}
	// The fresh strike is still inside the window: one more trips it.
	if !r.RecordInferenceError("p1", "m1", 500, "base") {
		t.Fatal("two strikes inside the window must trip the breaker")
	}
	if !r.InferenceErrorCooldownActive("p1", "m1", "base") {
		t.Fatal("cooldown should be active after the breaker tripped")
	}
}

func TestInferenceErrorCooldownScopedToPair(t *testing.T) {
	r := newTestManager(testLogger())
	r.RecordInferenceError("p1", "m1", 500, "base")
	r.RecordInferenceError("p1", "m1", 500, "base")

	if !r.InferenceErrorCooldownActive("p1", "m1", "base") {
		t.Fatal("expected active cooldown for the failing pair")
	}
	// Scoped to the triple: same provider other model, other provider same
	// model, and same pair other shape all still route.
	if r.InferenceErrorCooldownActive("p1", "m2", "base") || r.InferenceErrorCooldownActive("p2", "m1", "base") {
		t.Fatal("cooldown leaked beyond the failing provider-model pair")
	}
	if r.InferenceErrorCooldownActive("p1", "m1", "tools") {
		t.Fatal("cooldown leaked beyond the failing shape bucket")
	}
}

func TestInferenceErrorCooldownExpires(t *testing.T) {
	r := newTestManager(testLogger())
	r.RecordInferenceError("p1", "m1", 500, "base")
	r.RecordInferenceError("p1", "m1", 500, "base")

	now := time.Now()
	if !inferenceCooldownActiveAt(r, "p1", "m1", "base", now) {
		t.Fatal("cooldown should be active immediately after tripping")
	}
	if inferenceCooldownActiveAt(r, "p1", "m1", "base", now.Add(inferenceErrorCooldownTTL+time.Second)) {
		t.Fatal("cooldown survived past its TTL")
	}
}

func TestRecordInferenceSuccessClearsCooldownAndStrikes(t *testing.T) {
	r := newTestManager(testLogger())

	// Success clears an ACTIVE cooldown.
	r.RecordInferenceError("p1", "m1", 500, "base")
	r.RecordInferenceError("p1", "m1", 500, "base")
	if !r.InferenceErrorCooldownActive("p1", "m1", "base") {
		t.Fatal("expected active cooldown before success")
	}
	r.RecordInferenceSuccess("p1", "m1", "base")
	if r.InferenceErrorCooldownActive("p1", "m1", "base") {
		t.Fatal("RecordInferenceSuccess must clear an active cooldown")
	}

	// Success also clears STRIKES: error, success, error must not trip — the
	// post-success error is the FIRST strike of a fresh window.
	r.RecordInferenceError("p2", "m1", 500, "base")
	r.RecordInferenceSuccess("p2", "m1", "base")
	if r.RecordInferenceError("p2", "m1", 500, "base") {
		t.Fatal("strike before a success must not combine with one after it")
	}
	if r.InferenceErrorCooldownActive("p2", "m1", "base") {
		t.Fatal("cooldown must not be active after success cleared the first strike")
	}
	// Sanity: a genuine second strike still trips.
	if !r.RecordInferenceError("p2", "m1", 500, "base") {
		t.Fatal("two fresh strikes must still trip the breaker")
	}
}

// Root-bug regression: a deterministic tool/template failure interleaved with
// clean text ("base") successes must still accumulate to the threshold and trip
// the TOOLS cooldown — because a base success clears ONLY the base bucket, never
// the tools strikes. Before shape-keying, a shared counter meant each text
// success reset the strikes and the broken provider was never quarantined for
// tools.
func TestInferenceErrorShapeKeyedBucketsIndependent(t *testing.T) {
	r := newTestManager(testLogger())

	// Interleave: tools-failure, base-success, tools-failure, base-success.
	if r.RecordInferenceError("p1", "m1", 500, "tools") {
		t.Fatal("first tools strike must not trip")
	}
	r.RecordInferenceSuccess("p1", "m1", "base") // clean text success
	if !r.RecordInferenceError("p1", "m1", 500, "tools") {
		t.Fatal("second tools strike must trip the TOOLS breaker despite interleaved base successes")
	}
	r.RecordInferenceSuccess("p1", "m1", "base")

	// Tools is quarantined; base is clean.
	if !r.InferenceErrorCooldownActive("p1", "m1", "tools") {
		t.Fatal("tools cooldown must be active after two tools strikes")
	}
	if r.InferenceErrorCooldownActive("p1", "m1", "base") {
		t.Fatal("base bucket must stay clear — base successes must not be quarantined by tools failures")
	}

	// A base success must NOT clear the tools cooldown.
	r.RecordInferenceSuccess("p1", "m1", "base")
	if !r.InferenceErrorCooldownActive("p1", "m1", "tools") {
		t.Fatal("a base success must not clear the tools cooldown")
	}

	// A tools success clears ONLY the tools bucket.
	r.RecordInferenceSuccess("p1", "m1", "tools")
	if r.InferenceErrorCooldownActive("p1", "m1", "tools") {
		t.Fatal("a tools success must clear the tools cooldown")
	}

	// Symmetric: a tools success must not clear accumulated base strikes. Seed
	// one base strike, take a tools success, then a second base strike trips.
	r.RecordInferenceError("p1", "m1", 500, "base")
	r.RecordInferenceSuccess("p1", "m1", "tools")
	if !r.RecordInferenceError("p1", "m1", 500, "base") {
		t.Fatal("two base strikes must trip even with an interleaved tools success")
	}
	if !r.InferenceErrorCooldownActive("p1", "m1", "base") {
		t.Fatal("base cooldown must be active after two base strikes")
	}
}

// ageInferenceStrikes rewinds every recorded strike for the (provider, model,
// shape) triple by d, simulating the passage of time without sleeping in the
// test.
func ageInferenceStrikes(r *testManager, providerID, modelID, shape string, d time.Duration) {
	withGateForSession(r, providerID, func(g *gateState) {
		key := modelShapeKey{Model: modelID, Shape: shape}
		strikes := g.inferenceErrorStrikes[key]
		aged := make([]time.Time, len(strikes))
		for i, ts := range strikes {
			aged[i] = ts.Add(-d)
		}
		g.inferenceErrorStrikes[key] = aged
	})
}
