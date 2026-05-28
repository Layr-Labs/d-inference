package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const livenessAdminKey = "test-admin-key"

func livenessTestServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	st := store.NewMemory("")
	srv := NewServer(reg, st, logger)
	srv.SetAdminKey(livenessAdminKey)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, ts
}

func adminGET(t *testing.T, ts *httptest.Server, path string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, ts.URL+path, nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+livenessAdminKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("Do: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

func seedReliability(t *testing.T, st store.Store, providerID string, uptime float64, sessions int) {
	t.Helper()
	if err := st.UpsertReliabilityFeatures(context.Background(), store.ReliabilityFeatures{
		ProviderID:           providerID,
		UpdatedAt:            time.Now(),
		WindowDays:           14,
		UptimePct:            uptime,
		SessionsCount:        sessions,
		MTBFSeconds:          3600,
		MedianSessionSeconds: 1800,
		P10SessionSeconds:    600,
		P90SessionSeconds:    7200,
		PStays4h:             0.4,
		PStays8h:             0.1,
	}); err != nil {
		t.Fatalf("UpsertReliabilityFeatures: %v", err)
	}
}

func TestLivenessEndpointsRequireAdmin(t *testing.T) {
	_, ts := livenessTestServer(t)

	paths := []string{
		"/v1/providers/p1/liveness",
		"/v1/providers/p1/sessions",
		"/v1/providers/p1/heartbeats",
		"/v1/providers/reliability",
		"/v1/network/availability",
	}
	for _, p := range paths {
		resp, err := http.Get(ts.URL + p)
		if err != nil {
			t.Fatalf("GET %s: %v", p, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusForbidden {
			t.Fatalf("GET %s without admin: want 403, got %d", p, resp.StatusCode)
		}
	}
}

func TestLivenessProviderSummary(t *testing.T) {
	srv, ts := livenessTestServer(t)
	seedReliability(t, srv.store, "p1", 0.97, 12)

	// Found.
	code, body := adminGET(t, ts, "/v1/providers/p1/liveness")
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d body=%s", code, body)
	}
	var got store.ReliabilityFeatures
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, body)
	}
	if got.ProviderID != "p1" || got.UptimePct != 0.97 || got.SessionsCount != 12 {
		t.Fatalf("unexpected row: %+v", got)
	}

	// Not found.
	code, _ = adminGET(t, ts, "/v1/providers/nonexistent/liveness")
	if code != http.StatusNotFound {
		t.Fatalf("missing provider: want 404, got %d", code)
	}
}

func TestLivenessProviderSessions(t *testing.T) {
	srv, ts := livenessTestServer(t)
	now := time.Now()
	id, err := srv.store.OpenSession(context.Background(), store.SessionStart{
		ProviderID: "p1", ConnectedAt: now.Add(-1 * time.Hour), CoordinatorID: "coord-A",
	})
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	if err := srv.store.CloseSession(context.Background(), id, store.DisconnectReasonCleanClose, now, now.Add(-5*time.Minute), 3, 100); err != nil {
		t.Fatalf("CloseSession: %v", err)
	}

	code, body := adminGET(t, ts, "/v1/providers/p1/sessions?window=24h&limit=10")
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d body=%s", code, body)
	}
	var resp struct {
		Window  string             `json:"window"`
		Entries []store.SessionRow `json:"entries"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, body)
	}
	if resp.Window != "24h" {
		t.Fatalf("echo window: want 24h, got %q", resp.Window)
	}
	if len(resp.Entries) != 1 || resp.Entries[0].ProviderID != "p1" {
		t.Fatalf("unexpected entries: %+v", resp.Entries)
	}

	// Bad window.
	code, _ = adminGET(t, ts, "/v1/providers/p1/sessions?window=99d")
	if code != http.StatusBadRequest {
		t.Fatalf("bad window: want 400, got %d", code)
	}
}

func TestLivenessProviderHeartbeats(t *testing.T) {
	srv, ts := livenessTestServer(t)
	now := time.Now()
	if err := srv.store.AppendHeartbeats(context.Background(), []store.HeartbeatEvent{
		{ProviderID: "p1", At: now.Add(-2 * time.Minute), Status: "ok", MemoryPressure: 0.2, CPUUsage: 0.5, ThermalState: "nominal"},
		{ProviderID: "p1", At: now.Add(-1 * time.Minute), Status: "ok", MemoryPressure: 0.3, CPUUsage: 0.6, ThermalState: "fair"},
	}); err != nil {
		t.Fatalf("AppendHeartbeats: %v", err)
	}

	code, body := adminGET(t, ts, "/v1/providers/p1/heartbeats?window=24h&limit=10")
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d body=%s", code, body)
	}
	var resp struct {
		Window  string                 `json:"window"`
		Entries []store.HeartbeatEvent `json:"entries"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, body)
	}
	if len(resp.Entries) != 2 {
		t.Fatalf("want 2 heartbeats, got %d", len(resp.Entries))
	}
}

func TestLivenessProviderReliability(t *testing.T) {
	srv, ts := livenessTestServer(t)
	seedReliability(t, srv.store, "p1", 0.99, 50) // above bar
	seedReliability(t, srv.store, "p2", 0.80, 30) // below bar

	code, body := adminGET(t, ts, "/v1/providers/reliability?min_uptime=0.9&limit=10")
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d body=%s", code, body)
	}
	var resp struct {
		MinUptime float64                     `json:"min_uptime"`
		Entries   []store.ReliabilityFeatures `json:"entries"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, body)
	}
	if resp.MinUptime != 0.9 {
		t.Fatalf("echo min_uptime: want 0.9, got %v", resp.MinUptime)
	}
	if len(resp.Entries) != 1 || resp.Entries[0].ProviderID != "p1" {
		t.Fatalf("filter broken: %+v", resp.Entries)
	}
}

func TestLivenessNetworkAvailability(t *testing.T) {
	srv, ts := livenessTestServer(t)
	seedReliability(t, srv.store, "p1", 0.99, 50)
	seedReliability(t, srv.store, "p2", 0.95, 40)
	seedReliability(t, srv.store, "p3", 0.50, 10)

	code, body := adminGET(t, ts, "/v1/network/availability")
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d body=%s", code, body)
	}
	var resp map[string]any
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, body)
	}
	if got := int(resp["providers"].(float64)); got != 3 {
		t.Fatalf("providers: want 3, got %d", got)
	}
	if got := int(resp["highly_reliable"].(float64)); got != 2 {
		t.Fatalf("highly_reliable (≥0.95): want 2, got %d", got)
	}
	mean := resp["mean_uptime_pct"].(float64)
	if mean < 0.80 || mean > 0.82 { // (0.99+0.95+0.50)/3 ≈ 0.813
		t.Fatalf("mean off: %v", mean)
	}
	// At N=3 with sorted [0.50, 0.95, 0.99], nearest-rank percentile picks:
	//   p10 → idx round(0.2) = 0 → 0.50
	//   p50 → idx round(1.0) = 1 → 0.95
	//   p90 → idx round(1.8) = 2 → 0.99
	if got := resp["p10_uptime_pct"].(float64); got != 0.50 {
		t.Fatalf("p10: want 0.50, got %v", got)
	}
	if got := resp["p50_uptime_pct"].(float64); got != 0.95 {
		t.Fatalf("p50: want 0.95, got %v", got)
	}
	if got := resp["p90_uptime_pct"].(float64); got != 0.99 {
		t.Fatalf("p90: want 0.99, got %v", got)
	}
}

func TestLivenessNetworkAvailabilityEmpty(t *testing.T) {
	_, ts := livenessTestServer(t)
	code, body := adminGET(t, ts, "/v1/network/availability")
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d body=%s", code, body)
	}
	var resp map[string]any
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, body)
	}
	if got := int(resp["providers"].(float64)); got != 0 {
		t.Fatalf("empty fleet: want 0 providers, got %d", got)
	}
}
