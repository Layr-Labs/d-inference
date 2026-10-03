package operations_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/api/types"
)

func TestHealthExposesCoordinatorBuildIdentity(t *testing.T) {
	originalVersion, originalCommit, originalDate := api.BuildVersion, api.BuildCommit, api.BuildDate
	api.BuildVersion = "0.7.13"
	api.BuildCommit = "0123456789abcdef"
	api.BuildDate = "2026-07-17T23:45:00Z"
	t.Cleanup(func() {
		api.BuildVersion, api.BuildCommit, api.BuildDate = originalVersion, originalCommit, originalDate
	})

	srv := testkit.New(t, api.ServerConfig{}).Server
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
	if health.Version != api.BuildVersion ||
		health.BuildCommit != api.BuildCommit ||
		health.BuildDate != api.BuildDate {
		t.Fatalf("health build identity=%+v", health)
	}
}
