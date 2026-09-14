package api

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

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
	reg, st, srv, ts := setupTTFTFailoverServer(t)
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
	request := dispatch.Request{
		Model:                 model,
		PublicModel:           model,
		RawBody:               []byte(`{"model":"` + model + `"}`),
		ConsumerKey:           "test-key",
		EstimatedPromptTokens: 6,
		RequestedMaxTokens:    64,
		// ReceivedAt unstamped: per-attempt relative timers (invariant 5).
		Timing:   &registry.RequestTiming{},
		Deadline: deadline,
		// Keep the speculative launch point far past the per-attempt deadline
		// so every attempt performs exactly ONE dispatch (no backup race).
		SpeculativeAt:     10 * deadline,
		RefundReservation: func() {},
	}

	start := time.Now()
	srv.observeRequestOutcome(func(ow http.ResponseWriter, incoming *http.Request) {
		request.Profile = srv.newRequestProfile(incoming, model, model, false)
		srv.inferenceDispatch().Run(ow, incoming, request)
	})(w, r)
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
	// Sanity on the wall clock: 3 timed-out windows plus overhead, never the
	// 5-provider (or 64-attempt) walk.
	if elapsed > 4*time.Second {
		t.Errorf("dispatch took %s — the capped ladder must return promptly", elapsed)
	}
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	timeouts := 0
	for _, a := range outcome.Attempts {
		if a.RawReason == "first_chunk_timeout" {
			timeouts++
		}
	}
	if outcome.Termination != "rejected" || outcome.NormalizedCode != "ext_first_content_timeout" || timeouts != maxFirstChunkTimeoutRetries {
		t.Fatalf("timeout accounting %+v", outcome)
	}
}
