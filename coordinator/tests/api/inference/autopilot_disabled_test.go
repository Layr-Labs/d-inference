package inference_test

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

func TestAutopilotDemandDisabledLeavesExistingProfilerBehavior(t *testing.T) {
	observer := &observation.Owner{}
	srv := inference.New(inference.Dependencies{Observation: observer}, inference.Config{})
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	got, d := srv.BeginAutopilotDemand(r, time.Now())
	if got != r || d != nil || inference.AutopilotDemandFromContext(got.Context()) != nil {
		t.Fatal("disabled controller created demand state")
	}
	if rp := observer.NewRequestProfile(r, "m", "m", false); rp != nil {
		t.Fatal("disabled controller enabled profiling")
	}
}
