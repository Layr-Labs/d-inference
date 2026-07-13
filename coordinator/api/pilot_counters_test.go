//go:build pilotload

package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPilotCountersRequireSecretAndLoopback(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PILOT_COUNTER_TOKEN", "0123456789abcdef0123456789abcdef")
	_, _, _, server := setupTestServer(t)
	defer server.Close()

	request, err := http.NewRequest(http.MethodGet, server.URL+pilotCounterPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d, want 401", response.StatusCode)
	}

	request, err = http.NewRequest(http.MethodGet, server.URL+pilotCounterPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer 0123456789abcdef0123456789abcdef")
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("authorized status = %d, want 200", response.StatusCode)
	}
	var document struct {
		PilotCounters map[string]int `json:"pilot_counters"`
	}
	if err := json.NewDecoder(response.Body).Decode(&document); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		"mailbox_used",
		"mailbox_capacity",
		"database_pool_used",
		"database_pool_capacity",
		"provider_sessions",
		"protocol_v1_sessions",
		"protocol_v2_sessions",
		"untrusted_sessions",
		"self_signed_sessions",
		"hardware_sessions",
	} {
		if _, ok := document.PilotCounters[name]; !ok {
			t.Fatalf("counter %q is missing", name)
		}
	}
}

func TestPilotCountersAreNotRegisteredWithoutLongSecret(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PILOT_COUNTER_TOKEN", "short")
	_, _, _, server := setupTestServer(t)
	defer server.Close()

	response, err := http.Get(server.URL + pilotCounterPath)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", response.StatusCode)
	}
}

func TestPilotCountersRejectNonLoopbackRemoteAddress(t *testing.T) {
	t.Setenv("EIGENINFERENCE_PILOT_COUNTER_TOKEN", "0123456789abcdef0123456789abcdef")
	_, _, _, server := setupTestServer(t)
	defer server.Close()

	request := httptest.NewRequest(http.MethodGet, pilotCounterPath, nil)
	request.RemoteAddr = "203.0.113.7:1234"
	request.Header.Set("Authorization", "Bearer 0123456789abcdef0123456789abcdef")
	recorder := httptest.NewRecorder()
	server.Config.Handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", recorder.Code)
	}
}
