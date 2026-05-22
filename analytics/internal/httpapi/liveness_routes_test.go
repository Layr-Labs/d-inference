package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/analytics/internal/leaderboard"
	"github.com/eigeninference/analytics/internal/liveness"
	"github.com/eigeninference/analytics/internal/pseudonym"
)

// newLivenessTestServer wires the real liveness service against an in-memory
// store seeded with deterministic data, exposes it via httptest, and returns
// the URL plus the aliaser so tests can compute expected alias values.
func newLivenessTestServer(t *testing.T) (string, liveness.Aliaser, *liveness.MemoryStore) {
	t.Helper()
	store := liveness.NewMemoryStore()

	aliaser, err := pseudonym.NewGenerator("test-secret")
	if err != nil {
		t.Fatalf("NewGenerator: %v", err)
	}
	svc := liveness.NewService(store, aliaser, func() time.Time {
		return time.Date(2026, 5, 22, 12, 0, 0, 0, time.UTC)
	})

	// Need to satisfy the (unused-for-this-test) leaderboard.Service too;
	// reuse the memory backend with a wide active-window so /v1/overview
	// doesn't blow up if a future test calls it.
	lbStore := leaderboard.NewMemoryStore(2 * time.Minute)
	lbSvc := leaderboard.NewService(lbStore, aliaser, time.Now)

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(logger, lbSvc, svc, "*")
	srv := httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	return srv.URL, aliaser, store
}

func getJSON(t *testing.T, url string, into any) int {
	t.Helper()
	resp, err := http.Get(url)
	if err != nil {
		t.Fatalf("GET %s: %v", url, err)
	}
	defer resp.Body.Close()
	if into != nil {
		body, _ := io.ReadAll(resp.Body)
		if len(body) > 0 {
			if err := json.Unmarshal(body, into); err != nil {
				t.Fatalf("decode %s: %v body=%s", url, err, body)
			}
		}
	}
	return resp.StatusCode
}

func TestProviderLivenessRouteAliasesID(t *testing.T) {
	base, aliaser, store := newLivenessTestServer(t)

	store.SeedReliability(liveness.ReliabilityRow{
		ProviderID: "real-id-A",
		WindowDays: 14,
		UptimePct:  0.97,
	})

	var got liveness.Summary
	code := getJSON(t, base+"/v1/providers/real-id-A/liveness", &got)
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d", code)
	}
	if got.Alias != aliaser.Alias("provider", "real-id-A") {
		t.Fatalf("alias mismatch: %q", got.Alias)
	}
	if got.UptimePct != 0.97 {
		t.Fatalf("uptime: want 0.97, got %v", got.UptimePct)
	}
}

func TestProviderLivenessRouteMissing404(t *testing.T) {
	base, _, _ := newLivenessTestServer(t)
	code := getJSON(t, base+"/v1/providers/nope/liveness", nil)
	if code != http.StatusNotFound {
		t.Fatalf("status: want 404, got %d", code)
	}
}

func TestProviderSessionsRouteShape(t *testing.T) {
	base, _, store := newLivenessTestServer(t)
	now := time.Now()
	store.SeedSessions("p", liveness.SessionRow{
		ID:               1,
		ProviderID:       "p",
		ConnectedAt:      now.Add(-time.Hour),
		DisconnectedAt:   now.Add(-30 * time.Minute),
		DisconnectReason: "clean_close",
	})

	var body struct {
		Window  string                  `json:"window"`
		Entries []liveness.SessionEntry `json:"entries"`
	}
	code := getJSON(t, base+"/v1/providers/p/sessions?window=24h", &body)
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d", code)
	}
	if body.Window != "24h" {
		t.Fatalf("window echo: want 24h, got %q", body.Window)
	}
	if len(body.Entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(body.Entries))
	}
	if body.Entries[0].DurationSeconds < 1700 || body.Entries[0].DurationSeconds > 1900 {
		t.Fatalf("duration off: %d", body.Entries[0].DurationSeconds)
	}
}

func TestReliabilityRouteFilterParams(t *testing.T) {
	base, _, store := newLivenessTestServer(t)
	store.SeedReliability(liveness.ReliabilityRow{ProviderID: "good", UptimePct: 0.99, PStays4h: 0.9})
	store.SeedReliability(liveness.ReliabilityRow{ProviderID: "bad", UptimePct: 0.4, PStays4h: 0.2})

	var body struct {
		Entries []liveness.ReliabilityEntry `json:"entries"`
	}
	code := getJSON(t, base+"/v1/providers/reliability?min_uptime=0.9&min_stays_4h=0.8", &body)
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d", code)
	}
	if len(body.Entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(body.Entries))
	}
}

func TestNetworkAvailabilityRouteAggregates(t *testing.T) {
	base, _, store := newLivenessTestServer(t)
	for i, u := range []float64{0.4, 0.7, 0.95, 0.99} {
		store.SeedReliability(liveness.ReliabilityRow{
			ProviderID: "p-" + strconv.Itoa(i),
			WindowDays: 14,
			UptimePct:  u,
		})
	}

	var body liveness.FleetAvailability
	code := getJSON(t, base+"/v1/network/availability", &body)
	if code != http.StatusOK {
		t.Fatalf("status: want 200, got %d", code)
	}
	if body.Providers != 4 {
		t.Fatalf("providers: want 4, got %d", body.Providers)
	}
	if body.HighlyReliable != 2 {
		t.Fatalf("highly_reliable: want 2, got %d", body.HighlyReliable)
	}
}

func TestLivenessRoutesNotRegisteredWhenServiceNil(t *testing.T) {
	// If livenessSvc is nil (memory-mode dev runs that didn't wire it),
	// the routes should return 404 rather than 500.
	aliaser, _ := pseudonym.NewGenerator("test-secret")
	lbStore := leaderboard.NewMemoryStore(2 * time.Minute)
	lbSvc := leaderboard.NewService(lbStore, aliaser, time.Now)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(logger, lbSvc, nil, "*")
	srv := httptest.NewServer(handler)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/v1/providers/anything/liveness")
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 when liveness not wired, got %d", resp.StatusCode)
	}
}
