package ingress

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
)

func TestPreferOwnerConstraintFailsBeforeQueueWithoutCapableFallback(t *testing.T) {
	srv, _ := testController(t)
	response := httptest.NewRecorder()

	handled := srv.visionToolsFailFast(
		response,
		"model-build",
		"public-model",
		false,
		true,
		true,
		"required",
		false,
		dispatch.RoutePolicy{Prefer: true, OwnerAccountID: "owner"},
		nil,
	)
	if !handled {
		t.Fatal("incapable prefer-owner request was allowed to enter the queue")
	}
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503: %s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), "inference-time tool_choice enforcement") {
		t.Fatalf("wrong capability error: %s", response.Body.String())
	}
}
