package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

func TestHealthExposesCoordinatorBuildIdentity(t *testing.T) {
	originalVersion, originalCommit, originalDate := BuildVersion, BuildCommit, BuildDate
	BuildVersion = "0.7.11"
	BuildCommit = "0123456789abcdef"
	BuildDate = "2026-07-17T23:45:00Z"
	t.Cleanup(func() {
		BuildVersion, BuildCommit, BuildDate = originalVersion, originalCommit, originalDate
	})

	srv, _ := testServer(t)
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	response := httptest.NewRecorder()
	srv.Handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("health status=%d body=%s", response.Code, response.Body.String())
	}
	var health types.HealthResponse
	if err := json.Unmarshal(response.Body.Bytes(), &health); err != nil {
		t.Fatal(err)
	}
	if health.Version != BuildVersion ||
		health.BuildCommit != BuildCommit ||
		health.BuildDate != BuildDate {
		t.Fatalf("health build identity=%+v", health)
	}
}
