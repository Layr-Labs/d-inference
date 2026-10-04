package inference_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/demand"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

// autopilotRequestFixture binds demand through the owner's request boundary,
// which tracks demand only once the registry's controller is configured.
func autopilotRequestFixture(t *testing.T, srv *serverFixture) (*http.Request, *demand.Request, inference.AdmissionRequest) {
	t.Helper()
	if err := srv.registry.ConfigureAutopilot(autopilot.DefaultConfig()); err != nil {
		t.Fatal(err)
	}
	r, d := srv.BeginAutopilotDemand(httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil), time.Now())
	if d == nil {
		t.Fatal("autopilot demand tracking was not enabled")
	}
	return r, d, inference.AdmissionRequest{Model: "model-build", EstimatedPromptTokens: 27, RequestedMaxTokens: 64}
}
