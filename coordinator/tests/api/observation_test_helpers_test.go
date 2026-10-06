package api_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

const envProfiler = "EIGENINFERENCE_PROFILER"

// Read public observer health instead of inspecting a different package's sink.
func requestOutcomeReceived(t *testing.T, s *edgeFixture) int64 {
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
