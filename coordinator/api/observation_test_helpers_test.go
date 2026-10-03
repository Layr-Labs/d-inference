package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

const envProfiler = "EIGENINFERENCE_PROFILER"
const envProfileSampleRate = "EIGENINFERENCE_PROFILE_SAMPLE_RATE"

func installOutcomeObserver(t *testing.T, s *Server) {
	t.Helper()
	t.Setenv(envProfiler, "off")
	s.observation = observation.New(observation.Dependencies{Store: s.store, Registry: s.registry, Logger: s.logger, Hooks: observation.Hooks{
		RoutePattern: func(r *http.Request) string {
			if s.mux == nil {
				return http.MethodPost + " " + r.URL.Path
			}
			_, p := s.mux.Handler(r)
			return p
		},
		RequireAdminKey: func(http.ResponseWriter, *http.Request) bool { return true },
	}})
	t.Cleanup(s.observation.Close)
}

// Read public observer health instead of inspecting a different package's sink.
func requestOutcomeReceived(t *testing.T, s *Server) int64 {
	t.Helper()
	if s.access != nil {
		s.access.SetAdminKey("outcome-health-test")
	}
	r := httptest.NewRequest(http.MethodGet, "/v1/admin/request-outcomes", nil)
	r.Header.Set("Authorization", "Bearer outcome-health-test")
	w := httptest.NewRecorder()
	s.observation.HandleAdminRequestOutcomes(w, r)
	var body struct {
		Process struct {
			Received int64 `json:"received"`
		} `json:"process_counters"`
	}
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &body) != nil {
		t.Fatalf("observer health %d %s", w.Code, w.Body.String())
	}
	return body.Process.Received
}
