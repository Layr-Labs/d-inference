//go:build !pilotload

package api

import (
	"net/http"
	"testing"
)

func TestProductionBuildDoesNotRegisterPilotCounters(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PILOT_COUNTER_TOKEN", "0123456789abcdef0123456789abcdef")
	_, _, _, server := setupTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + "/_pilot/counters")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", response.StatusCode)
	}
}
