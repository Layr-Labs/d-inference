package api

// Terminal TTFT-rejection regression tests.
//
// A reservation that fails because every candidate exceeds the TTFT ceiling
// (errTTFTTooSlow, EIGENINFERENCE_TTFT_HARD_REJECT=true) is deterministic: the
// scheduler computes it from the same fleet-wide estimate on every scan, so
// re-running it within the same request cannot succeed. Pre-fix, only attempt 0
// failed fast; a MID-LADDER rejection (after an earlier provider error caused a
// failover) fell into the generic retry path and re-ran the doomed scan up to
// maxDispatchAttempts — in prod ~62.7 ttft_429 inference_routes rows per
// rejected request (28% of the table), the whole futile ladder completing in
// ~30ms. The fix terminates the ladder on the FIRST TTFT rejection at ANY
// attempt, gated by EIGENINFERENCE_TTFT_TERMINAL_REJECT (default true).

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// setupTTFTFailoverServer mirrors setupFailoverServer but returns the *Server
// so the test can flip the hard TTFT gate (the failover harness hides it).
func setupTTFTFailoverServer(t *testing.T) (*registry.Registry, *store.MemoryStore, *Server, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return reg, st, srv, ts
}

// makeProviderTTFTSlow stamps BackendCapacity (required for the scheduler's
// TTFT ceiling: providers without it are never TTFT-enforced) and a crawling
// prefill rate on a harness provider, so its estimated TTFT lands far above
// the ~5s prompt-scaled deadline and ReserveProviderEx TTFT-rejects it.
func makeProviderTTFTSlow(t *testing.T, reg *registry.Registry, registryID, model string) {
	t.Helper()
	p := reg.GetProvider(registryID)
	if p == nil {
		t.Fatalf("provider %q missing", registryID)
	}
	p.Mu().Lock()
	p.PrefillTPS = 0.2 // a handful of prompt tokens => ~25s+ estimated prefill
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model: model, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 200_000,
		}},
	}
	p.Mu().Unlock()
}

func countTTFT429Routes(st *store.MemoryStore) int {
	n := 0
	for _, rec := range st.InferenceRouteRecordsSince(time.Time{}) {
		if rec.Outcome == "ttft_429" {
			n++
		}
	}
	return n
}

// settleTTFT429Routes waits for the async route-telemetry sink to drain the
// request's writes, then returns the settled ttft_429 row count. It first waits
// for at least one row to land, then gives any storm of queued writes (the
// pre-fix 63-row ladder) time to flush before the exact-count assertion.
func settleTTFT429Routes(t *testing.T, st *store.MemoryStore) int {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && countTTFT429Routes(st) == 0 {
		time.Sleep(20 * time.Millisecond)
	}
	time.Sleep(300 * time.Millisecond)
	return countTTFT429Routes(st)
}

func rejectionReasons(st *store.MemoryStore) []string {
	reasons := make([]string, 0, 4)
	for _, rec := range st.RejectionRecordsSince(time.Time{}) {
		reasons = append(reasons, rec.ReasonCode)
	}
	return reasons
}

// TestDispatch_MidLadderTTFTReject_TerminatesImmediately is the regression for
// the prod 63-retry storm and FAILS without the fix. Provider A (fast, no
// BackendCapacity, so it is TTFT-blind for both the preflight and the
// scheduler ceiling) accepts the dispatch and errors pre-content with a
// genuine fault, which keeps the pre-content failover path alive. On the
// re-reserve, the remaining fleet (provider B: slow, WITH BackendCapacity) is
// TTFT-rejected — deterministically, on every scan. The ladder must terminate
// at that first mid-ladder rejection with the attempt-0-style 429
// (writeTTFTTooSlow body), one ttft_429 route row, and one ttft_too_slow
// rejection-ledger row — not walk to maxDispatchAttempts writing 63 junk rows
// and a dispatch_exhausted 429.
func TestDispatch_MidLadderTTFTReject_TerminatesImmediately(t *testing.T) {
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	srv.SetTTFTHardReject(true)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "mid-ladder-ttft-model"
	rec := &dispatchRecorder{}
	faultScript := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		rec.record(fp.name)
		fp.sendInferenceError(ctx, req, "internal error: simulated backend crash", http.StatusInternalServerError)
	}

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: faultScript,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: faultScript,
	})
	makeProviderTTFTSlow(t, reg, pB.registryID, model)

	start := time.Now()
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	elapsed := time.Since(start)

	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body = %s", status, body)
	}
	// The terminal response must be the attempt-0-style TTFT 429
	// (writeTTFTTooSlow: "... are above the Ns TTFT target ..."), NOT the
	// exhausted ladder's "all providers at capacity after 64 attempt(s)".
	if !strings.Contains(body, "above the") || !strings.Contains(body, "TTFT target") {
		t.Errorf("body is not the ttft_too_slow response: %s", body)
	}
	if strings.Contains(body, "attempt(s)") {
		t.Errorf("body is the dispatch-exhausted response — the ladder was not terminated at the TTFT rejection: %s", body)
	}
	if got := pA.dispatchCount() + pB.dispatchCount(); got != 1 {
		t.Errorf("total dispatches = %d, want 1 (A's pre-content fault only; B must never be dispatched)", got)
	}
	if elapsed > 5*time.Second {
		t.Errorf("request took %s — the terminal TTFT rejection must return promptly", elapsed)
	}

	// Exactly ONE ttft_429 route row (the mid-ladder rejection attempt) —
	// pre-fix the ladder wrote one per attempt up to maxDispatchAttempts.
	if got := settleTTFT429Routes(t, st); got != 1 {
		t.Errorf("ttft_429 route rows = %d, want exactly 1 (one reservation scan, then terminal)", got)
	}

	// The rejection ledger gets its single row, as ttft_too_slow (the exhausted
	// ladder's dispatch_exhausted row must NOT appear).
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && len(rejectionReasons(st)) == 0 {
		time.Sleep(20 * time.Millisecond)
	}
	reasons := rejectionReasons(st)
	ttftRows, otherRows := 0, []string{}
	for _, reason := range reasons {
		if reason == "ttft_too_slow" {
			ttftRows++
		} else {
			otherRows = append(otherRows, reason)
		}
	}
	if ttftRows != 1 || len(otherRows) != 0 {
		t.Errorf("rejection ledger rows = %v, want exactly one ttft_too_slow", reasons)
	}
}

// TestDispatch_TTFTRejectAttempt0_SingleReservationAnd429 pins the attempt-0
// contract the fix must preserve: when the very first reservation TTFT-rejects,
// exactly one dispatch attempt (one registry scan, one ttft_429 route row) is
// made, the response is the 429 ttft_too_slow body with Retry-After, the
// reservation is refunded exactly once, and the handler returns promptly. It
// drives dispatchState.run directly because on the HTTP path the hard-mode
// admission preflight (stage routing_ttft) sheds this fleet shape before the
// dispatch loop ever runs — prod reaches this code only when fleet state
// changes between preflight and reservation.
func TestDispatch_TTFTRejectAttempt0_SingleReservationAnd429(t *testing.T) {
	srv, st := testServer(t)
	srv.SetTTFTHardReject(true)
	const model = "attempt0-ttft-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	p := registerBuildsProvider(srv, "attempt0-slow-provider", model)
	p.Mu().Lock()
	p.DecodeTPS = 100
	p.PrefillTPS = 0.2 // TTFT estimate >> the ~5s deadline => reservation TTFT-rejects
	p.Mu().Unlock()

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	refunds := 0
	deadline := ttftDeadline(6)
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
		timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
		deadline:              deadline,
		speculativeAt:         deadline / 2,
		refundReservation:     func() { refunds++ },
		excludeProviders:      make(map[string]struct{}),
	}

	start := time.Now()
	d.run()
	elapsed := time.Since(start)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body = %s", w.Code, w.Body.String())
	}
	if body := w.Body.String(); !strings.Contains(body, "TTFT target") || !strings.Contains(body, "above the") {
		t.Errorf("body is not the ttft_too_slow response: %s", body)
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("Retry-After header missing")
	}
	if d.attempt != 0 {
		t.Errorf("dispatch attempts = %d, want the loop to stop at attempt 0", d.attempt+1)
	}
	if refunds != 1 {
		t.Errorf("reservation refunds = %d, want exactly 1", refunds)
	}
	if elapsed > 3*time.Second {
		t.Errorf("dispatch took %s — the TTFT rejection must return promptly", elapsed)
	}
	if got := settleTTFT429Routes(t, st); got != 1 {
		t.Errorf("ttft_429 route rows = %d, want exactly 1 (exactly one reservation scan)", got)
	}
}

// TestTTFTTerminalRejectKillSwitch pins the env wiring: default ON, only an
// explicit falsey value restores the legacy attempt-0-only behavior.
func TestTTFTTerminalRejectKillSwitch(t *testing.T) {
	t.Setenv(envTTFTTerminalReject, "")
	if !ttftTerminalRejectEnabled() {
		t.Fatal("terminal TTFT rejection must default to enabled")
	}
	t.Setenv(envTTFTTerminalReject, "false")
	if ttftTerminalRejectEnabled() {
		t.Fatal("EIGENINFERENCE_TTFT_TERMINAL_REJECT=false must disable the terminal rejection")
	}
	t.Setenv(envTTFTTerminalReject, "true")
	if !ttftTerminalRejectEnabled() {
		t.Fatal("EIGENINFERENCE_TTFT_TERMINAL_REJECT=true must enable the terminal rejection")
	}
}

// TestDispatch_MidLadderTTFTReject_KillSwitchRestoresLooping proves the kill
// switch end-to-end: with EIGENINFERENCE_TTFT_TERMINAL_REJECT=false the
// mid-ladder rejection falls back to the legacy retry loop, which re-runs the
// doomed scan to maxDispatchAttempts and returns the dispatch-exhausted 429
// with one ttft_429 row per futile attempt.
func TestDispatch_MidLadderTTFTReject_KillSwitchRestoresLooping(t *testing.T) {
	t.Setenv(envTTFTTerminalReject, "false")
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	srv.SetTTFTHardReject(true)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "killswitch-ttft-model"
	faultScript := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendInferenceError(ctx, req, "internal error: simulated backend crash", http.StatusInternalServerError)
	}
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: faultScript,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: faultScript,
	})
	makeProviderTTFTSlow(t, reg, pB.registryID, model)

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body = %s", status, body)
	}
	if !strings.Contains(body, "attempt(s)") {
		t.Errorf("kill switch must restore the legacy dispatch-exhausted response; body = %s", body)
	}
	if got := settleTTFT429Routes(t, st); got <= 1 {
		t.Errorf("ttft_429 route rows = %d, want the legacy multi-attempt ladder (> 1)", got)
	}
}
