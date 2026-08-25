package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPreContentTerminalRetainsHTTPStatus(t *testing.T) {
	srv := newTestServerForDispatch(t)
	rec := httptest.NewRecorder()
	d := &dispatchState{
		s:     srv,
		w:     rec,
		r:     httptest.NewRequest(http.MethodPost, "/v1/messages", nil),
		model: "m",
	}
	d.preContentTerminal(
		rejectionInfo{
			stage:         "queue",
			reasonCode:    "queue_timeout",
			httpStatus:    http.StatusTooManyRequests,
			resolvedModel: "m",
		},
		7,
		"rate_limit_exceeded",
		"at capacity",
		"rate_limit_exceeded",
	)

	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429", rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got != "7" {
		t.Fatalf("Retry-After = %q, want 7", got)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "rate_limit_exceeded") {
		t.Fatalf("status-coded rejection lost error body: %s", body)
	}
	if strings.Contains(body, "data:") || strings.Contains(body, ": keepalive") {
		t.Fatalf("pre-content terminal wrote SSE bytes: %s", body)
	}
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
