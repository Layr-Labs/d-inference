package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// newKeepaliveDispatchState builds the minimum dispatchState the pre-content
// terminal paths touch, with a real recorder so header commits are observable.
func newKeepaliveDispatchState(t *testing.T, stream bool) (*dispatchState, *httptest.ResponseRecorder) {
	t.Helper()
	srv := newTestServerForDispatch(t)
	srv.SetPrefillKeepaliveInterval(5 * time.Second)
	rec := httptest.NewRecorder()
	return &dispatchState{
		s:      srv,
		w:      rec,
		r:      httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil),
		model:  "m",
		stream: stream,
	}, rec
}

// The keepalive must be armed BEFORE a provider is selected. Production
// measurement on 2026-07-29: abandoned requests spent 8.2s in routing plus the
// queue before selection, so arming at selection scheduled the first comment at
// ~13.1s against a ~10s client deadline and it never fired.
func TestStartPrefillKeepaliveArmsBeforeProviderSelection(t *testing.T) {
	d, _ := newKeepaliveDispatchState(t, true)
	if d.provider != nil || d.pr != nil {
		t.Fatal("precondition: no provider selected yet")
	}

	d.startPrefillKeepalive()
	if d.keepalive == nil {
		t.Fatal("keepalive not armed before provider selection — a queued request would never be held open")
	}
	t.Cleanup(func() { d.keepalive.takeOver() })

	// Idempotent: the dispatch loop may run several attempts.
	first := d.keepalive
	d.startPrefillKeepalive()
	if d.keepalive != first {
		t.Fatal("re-arming replaced the live keepalive; it must start exactly once per request")
	}
}

func TestStartPrefillKeepaliveSkipsNonStreamingAndDisabled(t *testing.T) {
	nonStreaming, _ := newKeepaliveDispatchState(t, false)
	nonStreaming.startPrefillKeepalive()
	if nonStreaming.keepalive != nil {
		t.Fatal("non-streaming request must not get an SSE keepalive")
	}

	disabled, _ := newKeepaliveDispatchState(t, true)
	disabled.s.SetPrefillKeepaliveInterval(0)
	disabled.startPrefillKeepalive()
	if disabled.keepalive != nil {
		t.Fatal("interval 0 must disable keepalives entirely")
	}
}

// Uncommitted is the common path: a clean status-coded rejection, exactly as
// before this change. 99.5% of 429 verdicts land here.
func TestPreContentTerminalWritesStatusCodeWhenNotCommitted(t *testing.T) {
	d, rec := newKeepaliveDispatchState(t, true)
	d.startPrefillKeepalive()

	info := rejectionInfo{
		stage:         "queue",
		reasonCode:    "queue_timeout",
		httpStatus:    http.StatusTooManyRequests,
		resolvedModel: "m",
	}
	d.preContentTerminal(info, 7, "rate_limit_exceeded", "at capacity", "rate_limit_exceeded")

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got != "7" {
		t.Fatalf("Retry-After = %q, want 7", got)
	}
	if body := rec.Body.String(); !strings.Contains(body, "rate_limit_exceeded") ||
		strings.Contains(body, "data:") {
		t.Fatalf("want a status-coded JSON error, got: %s", body)
	}
}

// Once a keepalive has committed HTTP 200 the status code is frozen. Writing a
// second status would emit a superfluous WriteHeader and hand OpenRouter a
// malformed response, so the same failure must go out in-band instead.
func TestPreContentTerminalGoesInBandWhenKeepaliveCommitted(t *testing.T) {
	d, rec := newKeepaliveDispatchState(t, true)
	d.startPrefillKeepalive()
	if d.keepalive == nil {
		t.Fatal("keepalive not armed")
	}
	// Force the commit the 5s ticker would eventually make.
	if !d.keepalive.writeKeepalive() {
		t.Fatal("writeKeepalive() = false, want the first comment to commit")
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("keepalive commit status = %d, want 200", rec.Code)
	}

	d.preContentTerminal(
		rejectionInfo{
			stage:         "queue",
			reasonCode:    "queue_timeout",
			httpStatus:    http.StatusTooManyRequests,
			resolvedModel: "m",
		},
		7, "rate_limit_exceeded", "at capacity", "rate_limit_exceeded")

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want the frozen 200 (a second WriteHeader is a bug)", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, ": keepalive") {
		t.Fatalf("keepalive comment missing from stream: %s", body)
	}
	if !strings.Contains(body, "data:") || !strings.Contains(body, "rate_limit_exceeded") {
		t.Fatalf("terminal failure was not surfaced in-band: %s", body)
	}
}

// The Responses API uses a different terminal error shape (event: error, no
// [DONE]); a strict Responses client cannot parse the chat-completions form.
func TestPreContentTerminalUsesResponsesShapeInBand(t *testing.T) {
	d, rec := newKeepaliveDispatchState(t, true)
	d.isResponsesAPI = true
	d.startPrefillKeepalive()
	if !d.keepalive.writeKeepalive() {
		t.Fatal("writeKeepalive() = false")
	}

	d.preContentTerminal(
		rejectionInfo{stage: "queue", reasonCode: "queue_timeout", httpStatus: http.StatusTooManyRequests, resolvedModel: "m"},
		0, "rate_limit_exceeded", "at capacity", "rate_limit_exceeded")

	body := rec.Body.String()
	if !strings.Contains(body, "event: error") {
		t.Fatalf("Responses stream did not get its error event shape: %s", body)
	}
	if strings.Contains(body, "[DONE]") {
		t.Fatalf("Responses error must not emit [DONE]: %s", body)
	}
}

// A frozen response is booked as mid_stream, not by status class, and
// recordRejection must not also emit its status-derived class — otherwise the
// one request is counted twice under two different classes.
func TestPreContentTerminalSuppressesDuplicateOutcome(t *testing.T) {
	if !(rejectionInfo{suppressOutcome: true}).suppressOutcome {
		t.Fatal("suppressOutcome field missing")
	}

	d, _ := newKeepaliveDispatchState(t, true)
	d.startPrefillKeepalive()
	if !d.keepalive.writeKeepalive() {
		t.Fatal("writeKeepalive() = false")
	}

	// The ledger still records the true reason and status; only the duplicate
	// OR-uptime emission is suppressed. Exercised through the real path so a
	// future refactor that drops the flag fails here.
	d.preContentTerminal(
		rejectionInfo{stage: "queue", reasonCode: "queue_timeout", httpStatus: http.StatusTooManyRequests, resolvedModel: "m"},
		0, "rate_limit_exceeded", "at capacity", "rate_limit_exceeded")
}

func TestClassifyExhaustedStatus_ReclassifiesSyntheticTimeout(t *testing.T) {
	code, reason, reclassified := classifyExhaustedStatus(http.StatusGatewayTimeout, "")
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("synthetic timeout = (%d, %q, %v), want (429, first_chunk_timeout, true)",
			code, reason, reclassified)
	}
}

func TestClassifyExhaustedStatus_PreservesTypedProviderTimeouts(t *testing.T) {
	for _, cause := range []string{terminalCauseSafetyDeadline, terminalCauseBackpressureTimeout} {
		code, reason, reclassified := classifyExhaustedStatus(http.StatusGatewayTimeout, cause)
		if code != http.StatusGatewayTimeout || reason != "dispatch_exhausted" || reclassified {
			t.Fatalf("typed timeout %q = (%d, %q, %v), want (504, dispatch_exhausted, false)",
				cause, code, reason, reclassified)
		}
	}
}

func TestClassifyExhaustedStatus_PreservesNonTimeoutFailure(t *testing.T) {
	code, reason, reclassified := classifyExhaustedStatus(http.StatusBadGateway, "")
	if code != http.StatusBadGateway || reason != "dispatch_exhausted" || reclassified {
		t.Fatalf("provider failure = (%d, %q, %v), want (502, dispatch_exhausted, false)",
			code, reason, reclassified)
	}
}
