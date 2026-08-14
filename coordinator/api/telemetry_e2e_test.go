package api

// End-to-end route test for the fail-closed client telemetry sink.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestTelemetryE2E_IngestionDisabled(t *testing.T) {
	const sentinel = "PROMPT_SECRET_E2E_DO_NOT_EXFILTRATE"

	srv, _ := testServer(t)
	srv.SetAdminKey("admin-key")
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	resp, err := http.Post(
		ts.URL+"/v1/telemetry/events",
		"application/json",
		bytes.NewBufferString(`{"events":[{"message":"`+sentinel+`"}]}`),
	)
	if err != nil {
		t.Fatalf("ingest POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusGone {
		t.Fatalf("ingest status = %d, want %d", resp.StatusCode, http.StatusGone)
	}
	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if strings.Contains(string(responseBody), sentinel) {
		t.Fatalf("request data reflected in response: %s", responseBody)
	}

	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/admin/metrics", nil)
	req.Header.Set("Authorization", "Bearer admin-key")
	metricsResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("metrics: %v", err)
	}
	defer metricsResp.Body.Close()
	if metricsResp.StatusCode != http.StatusOK {
		t.Fatalf("metrics status: %d", metricsResp.StatusCode)
	}
	var snap MetricsSnapshot
	if err := json.NewDecoder(metricsResp.Body).Decode(&snap); err != nil {
		t.Fatalf("decode metrics: %v", err)
	}
	for key, value := range snap.Counters {
		if strings.HasPrefix(key, "telemetry_events_total") && value != 0 {
			t.Fatalf("ingest counter changed despite disabled sink: %s=%d", key, value)
		}
	}
}
