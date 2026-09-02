package api

// Timeout-class ladder cap regression tests (2026-09-01 congestion collapse).
//
// A first-chunk TIMEOUT (slow provider, reason "first_chunk_timeout") used to
// retry across the fleet with a fresh full reservation scan per attempt —
// unbounded except by maxDispatchAttempts=64 and the request-absolute
// first-content clock. Wall time per request was bounded; CPU was not:
// retry-amplified inbound (~100 req/s of retryable 429 traffic) times
// per-request fleet scans (~1,260 providers each) saturated every coordinator
// CPU into a stable death loop (attempt-0 route p50 40ms → 4.6s, success
// ~40%, 429s delivered after 11s). maxFirstChunkTimeoutRetries caps the
// timeout-class ladder the same way maxCapacityClassRetries caps capacity
// failovers, exhausting into the existing synthetic-timeout → 429
// reclassification (classifyExhaustedStatus).

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestDispatch_FirstChunkTimeoutLadder_CapsAtThreeAttempts drives the REAL
// dispatch loop (dispatchState.run, per the TestDispatch_TTFTRejectAttempt0
// pattern) against five real-WS providers that accept every frame and then go
// dead silent. ReceivedAt is deliberately UNSTAMPED so, per the historical
// relative-timer fallback (first_token_clock.go invariant 5), every attempt
// gets its own first-content window — exactly the configuration in which the
// pre-fix ladder could walk the whole fleet, one reservation scan per silent
// provider. The ladder must stop after maxFirstChunkTimeoutRetries dispatches
// (each on a DISTINCT provider — timed-out providers are excluded) and answer
// one retryable 429, not walk all five providers.
func TestDispatch_FirstChunkTimeoutLadder_CapsAtThreeAttempts(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "timeout-ladder-model"
	const fleet = 5 // more providers than the cap, so the cap — not candidate exhaustion — stops the loop
	providers := make([]*failoverProvider, 0, fleet)
	for i := 0; i < fleet; i++ {
		providers = append(providers, startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name:      fmt.Sprintf("silent-%d", i),
			Version:   "0.7.0",
			DecodeTPS: 100,
			Models:    []failoverModelSpec{{ID: model}},
			Script:    nil, // accept the dispatch, never answer: pure first-chunk timeout
		}))
	}

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	deadline := 150 * time.Millisecond
	d := &dispatchState{
		s:                     srv,
		w:                     w,
		r:                     r,
		model:                 model,
		publicModel:           model,
		rawBody:               []byte(`{"model":"` + model + `"}`),
		consumerKey:           "test-key",
		estimatedPromptTokens: 6,
		requestedMaxTokens:    64,
		// ReceivedAt unstamped: per-attempt relative timers (invariant 5).
		timing:   &registry.RequestTiming{},
		deadline: deadline,
		// Keep the speculative launch point far past the per-attempt deadline
		// so every attempt performs exactly ONE dispatch (no backup race).
		speculativeAt:     10 * deadline,
		refundReservation: func() {},
		excludeProviders:  map[string]struct{}{},
	}

	start := time.Now()
	d.run()
	elapsed := time.Since(start)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (timeout ladder → retryable 429); body=%s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "rate_limit_exceeded") {
		t.Errorf("body missing rate_limit_exceeded code; body=%s", w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("missing Retry-After header on the 429")
	}
	total := 0
	for _, fp := range providers {
		if n := fp.dispatchCount(); n > 1 {
			t.Errorf("provider %s received %d dispatches, want at most 1 (timed-out providers are excluded)", fp.name, n)
		} else {
			total += n
		}
	}
	if total != maxFirstChunkTimeoutRetries {
		t.Errorf("total dispatches = %d, want exactly %d — the timeout ladder must stop at the cap, not walk all %d providers",
			total, maxFirstChunkTimeoutRetries, fleet)
	}
	if d.firstChunkTimeoutRetries != maxFirstChunkTimeoutRetries {
		t.Errorf("firstChunkTimeoutRetries = %d, want %d", d.firstChunkTimeoutRetries, maxFirstChunkTimeoutRetries)
	}
	// Sanity on the wall clock: 3 timed-out windows plus overhead, never the
	// 5-provider (or 64-attempt) walk.
	if elapsed > 4*time.Second {
		t.Errorf("dispatch took %s — the capped ladder must return promptly", elapsed)
	}
}

// TestShouldStopFailover_TimeoutCapCountsOnlySyntheticTimeouts pins the
// counting rule at the unit level: only the untyped 504 (the dispatch loop's
// synthetic first-chunk timeout discriminator) consumes the timeout allowance;
// a TYPED provider 504 (safety_deadline — a real provider terminal) keeps its
// existing fault-failover behavior and consumes nothing.
func TestShouldStopFailover_TimeoutCapCountsOnlySyntheticTimeouts(t *testing.T) {
	srv, _ := testServer(t)
	d := &dispatchState{
		s:                srv,
		model:            "cap-count-model",
		excludeProviders: map[string]struct{}{},
	}

	// A typed provider 504 must not touch the timeout counter.
	d.setLastError("safety_deadline: safety ceiling expired", http.StatusGatewayTimeout)
	d.lastErrTerminalCause = terminalCauseSafetyDeadline
	if d.shouldStopFailover() {
		t.Fatal("typed provider 504 must keep the existing fault failover, not stop")
	}
	if d.firstChunkTimeoutRetries != 0 {
		t.Fatalf("typed 504 consumed the timeout allowance: %d", d.firstChunkTimeoutRetries)
	}

	// Synthetic timeouts stop at exactly maxFirstChunkTimeoutRetries.
	for i := 1; i < maxFirstChunkTimeoutRetries; i++ {
		d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
		if d.shouldStopFailover() {
			t.Fatalf("synthetic timeout %d stopped early (cap is %d)", i, maxFirstChunkTimeoutRetries)
		}
	}
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	if !d.shouldStopFailover() {
		t.Fatalf("synthetic timeout %d must stop the ladder", maxFirstChunkTimeoutRetries)
	}

	// The exhausted ladder must reclassify the latched synthetic 504 to the
	// retryable 429 with the closed first_chunk_timeout reason.
	failure, sticky := d.terminalFailureForExhaustion()
	code, reason, reclassified, dominance := d.resolveDominantExhaustedStatus(failure, sticky)
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("exhausted classification = (%d, %q, %v), want (429, first_chunk_timeout, true)", code, reason, reclassified)
	}
	if dominance != exhaustedUndecided {
		t.Fatalf("dominance = %d, want exhaustedUndecided (plain reclassified timeout)", dominance)
	}
}
