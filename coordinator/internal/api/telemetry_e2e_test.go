package api

// End-to-end style test: drives the coordinator's HTTP server with realistic
// ingestion traffic to validate the entire pipeline including Datadog forwarding
// (which is a no-op in tests since DD_API_KEY is unset).

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/telemetry"
)

// TestTelemetryE2E_FullPipeline drives the full coordinator-side telemetry
// pipeline: ingestion → in-memory store → metrics.
func TestTelemetryE2E_FullPipeline(t *testing.T) {
	srv, st := testServer(t)
	srv.SetAdminKey("admin-key")
	srv.SetEmitter(telemetry.NewEmitter(srv.logger, st, srv.metrics, "e2e-test"))

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// 1. Ingest a representative batch through the public endpoint.
	now := time.Now().UTC()
	ingest := protocol.TelemetryBatch{
		Events: []protocol.TelemetryEvent{
			{
				ID:        "00000000-0000-0000-0000-000000000010",
				Timestamp: now,
				Source:    protocol.TelemetrySourceProvider,
				Severity:  protocol.SeverityError,
				Kind:      protocol.KindBackendCrash,
				Version:   "0.3.10",
				MachineID: "m-e2e",
				Message:   "vllm-mlx died",
				Fields: map[string]any{
					"backend":   "vllm-mlx",
					"exit_code": 134,
					// Rejected — not on allowlist:
					"prompt": "ATTACKER_LEAK",
				},
				Stack: "at vllm_mlx::serve\n  at main",
			},
			{
				ID:        "00000000-0000-0000-0000-000000000011",
				Timestamp: now,
				Source:    protocol.TelemetrySourceConsole,
				Severity:  protocol.SeverityWarn,
				Kind:      protocol.KindHTTPError,
				Message:   "fetch failed",
				Fields: map[string]any{
					"url":         "https://api.darkbloom.dev/v1/models",
					"status_code": 500,
				},
			},
		},
	}
	body, _ := json.Marshal(ingest)
	resp, err := http.Post(ts.URL+"/v1/telemetry/events", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("ingest POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("ingest status: got %d want 202", resp.StatusCode)
	}

	// 2. Verify in-memory buffer contains the events and PII is stripped.
	events := st.TelemetryEventsSnapshot()
	if len(events) < 2 {
		t.Fatalf("stored events: got %d want >=2", len(events))
	}
	for _, e := range events {
		if strings.Contains(string(e.Fields), "ATTACKER_LEAK") {
			t.Fatalf("PII LEAKED into stored event: %+v", e)
		}
	}

	// 3. Metrics endpoint — JSON.
	req3, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/admin/metrics", nil)
	req3.Header.Set("Authorization", "Bearer admin-key")
	r3, err := http.DefaultClient.Do(req3)
	if err != nil {
		t.Fatalf("metrics: %v", err)
	}
	defer r3.Body.Close()
	if r3.StatusCode != http.StatusOK {
		t.Fatalf("metrics status: %d", r3.StatusCode)
	}
	var snap MetricsSnapshot
	if err := json.NewDecoder(r3.Body).Decode(&snap); err != nil {
		t.Fatalf("decode metrics: %v", err)
	}
	// The ingestion handler bumps telemetry_events_total per event. Two
	// events posted so we expect a count of >= 2 across all label sets.
	var total int64
	for k, v := range snap.Counters {
		if strings.HasPrefix(k, "telemetry_events_total") {
			total += v
		}
	}
	if total < 2 {
		t.Errorf("telemetry_events_total: got %d want >=2 (snapshot=%+v)", total, snap.Counters)
	}

	// 4. Metrics endpoint — Prometheus text format.
	req4, _ := http.NewRequest(http.MethodGet, ts.URL+"/v1/admin/metrics?format=prom", nil)
	req4.Header.Set("Authorization", "Bearer admin-key")
	r4, err := http.DefaultClient.Do(req4)
	if err != nil {
		t.Fatalf("metrics prom: %v", err)
	}
	defer r4.Body.Close()
	if r4.StatusCode != http.StatusOK {
		t.Fatalf("metrics prom status: %d", r4.StatusCode)
	}
	buf := new(bytes.Buffer)
	_, _ = buf.ReadFrom(r4.Body)
	if !strings.Contains(buf.String(), "# TYPE telemetry_events_total counter") {
		t.Errorf("missing TYPE line for telemetry_events_total in:\n%s", buf.String())
	}
	if !strings.Contains(buf.String(), "providers_online") {
		t.Errorf("missing providers_online gauge in:\n%s", buf.String())
	}
}
