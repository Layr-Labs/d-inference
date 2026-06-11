package registry

import (
	"fmt"
	"testing"
	"time"
)

func inferenceCooldownActiveAt(r *Registry, providerID, modelID string, now time.Time) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.inferenceErrorCooldownActiveLocked(providerID, modelID, now)
}

// ageInferenceStrikes rewinds every recorded strike for the pair by d,
// simulating the passage of time without sleeping in the test.
func ageInferenceStrikes(r *Registry, providerID, modelID string, d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := providerID + ":" + modelID
	strikes := r.inferenceErrorStrikes[key]
	aged := make([]time.Time, len(strikes))
	for i, ts := range strikes {
		aged[i] = ts.Add(-d)
	}
	r.inferenceErrorStrikes[key] = aged
}

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
			r := New(testLogger())
			for i, code := range tc.statusCodes {
				got := r.RecordInferenceError("p1", "m1", code)
				if got != tc.wantEntered[i] {
					t.Fatalf("call %d (status %d): enteredCooldown=%v, want %v", i, code, got, tc.wantEntered[i])
				}
			}
			if got := r.InferenceErrorCooldownActive("p1", "m1"); got != tc.wantActive {
				t.Fatalf("InferenceErrorCooldownActive=%v, want %v", got, tc.wantActive)
			}
		})
	}
}

func TestRecordInferenceErrorSlidingWindow(t *testing.T) {
	r := New(testLogger())
	if r.RecordInferenceError("p1", "m1", 500) {
		t.Fatal("first error must not trip the breaker")
	}
	// Age the first strike past the window: the next error stands alone.
	ageInferenceStrikes(r, "p1", "m1", inferenceErrorWindow+time.Second)
	if r.RecordInferenceError("p1", "m1", 500) {
		t.Fatal("a strike outside the sliding window must not count toward the threshold")
	}
	if r.InferenceErrorCooldownActive("p1", "m1") {
		t.Fatal("cooldown must not be active after the window slid past the first strike")
	}
	// The fresh strike is still inside the window: one more trips it.
	if !r.RecordInferenceError("p1", "m1", 500) {
		t.Fatal("two strikes inside the window must trip the breaker")
	}
	if !r.InferenceErrorCooldownActive("p1", "m1") {
		t.Fatal("cooldown should be active after the breaker tripped")
	}
}

func TestInferenceErrorCooldownScopedToPair(t *testing.T) {
	r := New(testLogger())
	r.RecordInferenceError("p1", "m1", 500)
	r.RecordInferenceError("p1", "m1", 500)

	if !r.InferenceErrorCooldownActive("p1", "m1") {
		t.Fatal("expected active cooldown for the failing pair")
	}
	// Scoped to the pair: same provider other model, and other provider same
	// model, still route.
	if r.InferenceErrorCooldownActive("p1", "m2") || r.InferenceErrorCooldownActive("p2", "m1") {
		t.Fatal("cooldown leaked beyond the failing provider-model pair")
	}
}

func TestInferenceErrorCooldownExpires(t *testing.T) {
	r := New(testLogger())
	r.RecordInferenceError("p1", "m1", 500)
	r.RecordInferenceError("p1", "m1", 500)

	now := time.Now()
	if !inferenceCooldownActiveAt(r, "p1", "m1", now) {
		t.Fatal("cooldown should be active immediately after tripping")
	}
	if inferenceCooldownActiveAt(r, "p1", "m1", now.Add(inferenceErrorCooldownTTL+time.Second)) {
		t.Fatal("cooldown survived past its TTL")
	}
}

func TestRecordInferenceSuccessClearsCooldownAndStrikes(t *testing.T) {
	r := New(testLogger())

	// Success clears an ACTIVE cooldown.
	r.RecordInferenceError("p1", "m1", 500)
	r.RecordInferenceError("p1", "m1", 500)
	if !r.InferenceErrorCooldownActive("p1", "m1") {
		t.Fatal("expected active cooldown before success")
	}
	r.RecordInferenceSuccess("p1", "m1")
	if r.InferenceErrorCooldownActive("p1", "m1") {
		t.Fatal("RecordInferenceSuccess must clear an active cooldown")
	}

	// Success also clears STRIKES: error, success, error must not trip — the
	// post-success error is the FIRST strike of a fresh window.
	r.RecordInferenceError("p2", "m1", 500)
	r.RecordInferenceSuccess("p2", "m1")
	if r.RecordInferenceError("p2", "m1", 500) {
		t.Fatal("strike before a success must not combine with one after it")
	}
	if r.InferenceErrorCooldownActive("p2", "m1") {
		t.Fatal("cooldown must not be active after success cleared the first strike")
	}
	// Sanity: a genuine second strike still trips.
	if !r.RecordInferenceError("p2", "m1", 500) {
		t.Fatal("two fresh strikes must still trip the breaker")
	}
}

func TestInferenceErrorMapsBounded(t *testing.T) {
	r := New(testLogger())
	// Trip the breaker for >1024 distinct dead pairs so both maps grow, then
	// force everything past expiry — the opportunistic sweep must drop them.
	for i := 0; i < 1100; i++ {
		id := fmt.Sprintf("dead-provider-%d", i)
		r.RecordInferenceError(id, "m", 500)
		r.RecordInferenceError(id, "m", 500)
	}
	r.mu.Lock()
	for k := range r.inferenceErrorCooldowns {
		r.inferenceErrorCooldowns[k] = time.Now().Add(-time.Second)
	}
	for k, strikes := range r.inferenceErrorStrikes {
		aged := make([]time.Time, len(strikes))
		for i, ts := range strikes {
			aged[i] = ts.Add(-(inferenceErrorWindow + time.Second))
		}
		r.inferenceErrorStrikes[k] = aged
	}
	cooldowns, strikes := len(r.inferenceErrorCooldowns), len(r.inferenceErrorStrikes)
	r.mu.Unlock()
	if cooldowns < 1000 || strikes < 1000 {
		t.Fatalf("setup produced too few distinct entries: cooldowns=%d strikes=%d", cooldowns, strikes)
	}

	r.RecordInferenceError("live", "m", 500)

	r.mu.Lock()
	cooldownsAfter, strikesAfter := len(r.inferenceErrorCooldowns), len(r.inferenceErrorStrikes)
	r.mu.Unlock()
	if cooldownsAfter != 0 {
		t.Fatalf("cooldown sweep should drop every expired entry (live pair has no cooldown yet), got %d", cooldownsAfter)
	}
	if strikesAfter != 1 {
		t.Fatalf("strike sweep should leave only the live entry, got %d", strikesAfter)
	}
}

// End-to-end through the production dispatch hot path (ReserveProviderEx): a
// pair quarantined by the inference-error breaker must be structurally
// excluded from candidates so selection falls to a healthy provider, a fully
// quarantined fleet yields no selection, and a success restores the pair.
func TestReserveProviderExSkipsInferenceErrorCooldown(t *testing.T) {
	reg := New(testLogger())
	model := "inference-error-model"
	bad := makeSchedulerProvider(t, reg, "bad", model, 200)
	good := makeSchedulerProvider(t, reg, "good", model, 50)

	req := func(id string) *PendingRequest {
		return &PendingRequest{RequestID: id, Model: model, RequestedMaxTokens: 128}
	}

	// 4xx (client-shape) and 503 (capacity/lifecycle) errors must not
	// deroute anyone.
	reg.RecordInferenceError(bad.ID, model, 400)
	reg.RecordInferenceError(bad.ID, model, 429)
	reg.RecordInferenceError(bad.ID, model, 503)
	if _, decision := reg.ReserveProviderEx(model, req("r-4xx")); decision.CandidateCount != 2 {
		t.Fatalf("4xx errors must not exclude a provider: CandidateCount=%d, want 2", decision.CandidateCount)
	}
	bad.RemovePending("r-4xx")
	good.RemovePending("r-4xx")

	// Two 5xx quarantine the bad pair: selection must fall to the other one.
	reg.RecordInferenceError(bad.ID, model, 500)
	if !reg.RecordInferenceError(bad.ID, model, 500) {
		t.Fatal("second 5xx should report the transition into cooldown")
	}
	selected, decision := reg.ReserveProviderEx(model, req("r1"))
	if selected == nil {
		t.Fatal("selection must fall to the healthy provider, got nil")
	}
	if selected.ID != good.ID {
		t.Fatalf("selected %q, want healthy provider %q", selected.ID, good.ID)
	}
	if decision.CandidateCount != 1 {
		t.Fatalf("CandidateCount=%d, want 1 (cooled pair structurally excluded)", decision.CandidateCount)
	}
	good.RemovePending("r1")

	// Quarantine the second provider too (502 = disconnect flush): nothing serves.
	reg.RecordInferenceError(good.ID, model, 502)
	reg.RecordInferenceError(good.ID, model, 502)
	if selected, _ := reg.ReserveProviderEx(model, req("r2")); selected != nil {
		t.Fatalf("selected %q, want nil when every pair is quarantined", selected.ID)
	}

	// A served request restores the pair immediately.
	reg.RecordInferenceSuccess(bad.ID, model)
	selected, _ = reg.ReserveProviderEx(model, req("r3"))
	if selected == nil || selected.ID != bad.ID {
		t.Fatalf("after success-clear expected %q to serve again, got %v", bad.ID, selected)
	}
}
