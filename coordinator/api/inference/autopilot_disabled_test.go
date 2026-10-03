package inference

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

func TestAutopilotDemandDisabledLeavesExistingProfilerBehavior(t *testing.T) {
	srv := &Owner{observation: &observation.Owner{}}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	got, d := srv.BeginAutopilotDemand(r, time.Now())
	if got != r || d != nil || AutopilotDemandFromContext(got.Context()) != nil {
		t.Fatal("disabled controller created demand state")
	}
	if rp := srv.observation.NewRequestProfile(r, "m", "m", false); rp != nil {
		t.Fatal("disabled controller enabled profiling")
	}
}
