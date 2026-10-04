package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPreContentTerminalRetainsHTTPStatus(t *testing.T) {
	srv := newTestServerForDispatch(t)
	rec := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/messages", nil)
	srv.NewRejectionRecorder().PreContentTerminal(
		rec, r,
		&store.RejectionRecord{
			Stage:         "queue",
			ReasonCode:    "queue_timeout",
			HTTPStatus:    http.StatusTooManyRequests,
			ResolvedModel: "m",
		},
		rejection.Servability{},
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
