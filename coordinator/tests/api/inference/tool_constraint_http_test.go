package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
)

func TestPreferOwnerConstraintFailsBeforeQueueWithoutCapableFallback(t *testing.T) {
	srv, _ := testServer(t)
	response := httptest.NewRecorder()

	handled := srv.NewCapabilityGate().Reject(
		response,
		"model-build",
		"public-model",
		false,
		true,
		true,
		"required",
		dispatch.Scope{PreferOwner: true, OwnerAccountID: "owner"},
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
