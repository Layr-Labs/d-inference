package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	infer "github.com/eigeninference/d-inference/coordinator/api/inference"
)

func TestAutopilotDemandDisabledLeavesExistingProfilerBehavior(t *testing.T) {
	srv := &Server{}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	got, d := srv.inference.BeginAutopilotDemand(r, time.Now())
	if got != r || d != nil || infer.AutopilotDemandFromContext(got.Context()) != nil {
		t.Fatal("disabled controller created demand state")
	}
	if rp := srv.observation.NewRequestProfile(r, "m", "m", false); rp != nil {
		t.Fatal("disabled controller enabled profiling")
	}
}
