package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type networkBindingStore struct {
	store.Store
	requests int64
}

func (s *networkBindingStore) UsageTotals() (store.UsageTotals, error) {
	return store.UsageTotals{Requests: s.requests}, nil
}

func (s *networkBindingStore) UsageTotalsSince(time.Time) (store.UsageTotals, error) {
	return s.UsageTotals()
}

func (s *networkBindingStore) UsageTimeSeries(start, _ time.Time, _ time.Duration) ([]store.UsageBucket, error) {
	return []store.UsageBucket{{Minute: start, Requests: s.requests}}, nil
}

func (s *networkBindingStore) NetworkTotals(time.Time) (store.NetworkTotalsRow, error) {
	return store.NetworkTotalsRow{Jobs: s.requests}, nil
}

func (s *networkBindingStore) Leaderboard(store.LeaderboardMetric, time.Time, int) []store.LeaderboardRow {
	return []store.LeaderboardRow{{AccountID: "private-account", Jobs: s.requests}}
}

// These requests use routes registered before dependency replacement. The
// extracted owner must retain the server's current bindings and shared cache.
func TestNetworkRoutesUseCurrentBindings(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	oldStore := &networkBindingStore{Store: store.NewMemory(store.Config{}), requests: 11}
	srv := NewServer(registry.New(logger), oldStore, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	handler := srv.Handler()
	read := func(path string) []byte {
		t.Helper()
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", path, rr.Code, rr.Body.String())
		}
		return rr.Body.Bytes()
	}
	checkStore := func(want int64) {
		t.Helper()
		for _, path := range []string{"/v1/stats", "/v1/network/totals", "/v1/network/series", "/v1/leaderboard"} {
			var body struct {
				Requests int64 `json:"total_requests"`
				Jobs     int64 `json:"jobs"`
				Series   []struct {
					Requests int64 `json:"requests"`
				} `json:"time_series"`
				Entries []struct {
					Jobs int64 `json:"jobs"`
				} `json:"entries"`
			}
			raw := read(path)
			if err := json.Unmarshal(raw, &body); err != nil {
				t.Fatal(err)
			}
			var got int64
			switch path {
			case "/v1/stats":
				got = body.Requests
			case "/v1/network/totals":
				got = body.Jobs
			case "/v1/network/series":
				if len(body.Series) != 1 {
					t.Fatalf("series rows: %s", raw)
				}
				got = body.Series[0].Requests
			case "/v1/leaderboard":
				if len(body.Entries) != 1 || bytes.Contains(raw, []byte("private-account")) {
					t.Fatalf("leaderboard entries: %s", raw)
				}
				got = body.Entries[0].Jobs
			}
			if got != want {
				t.Fatalf("%s: current store value = %d, want %d", path, got, want)
			}
		}
	}
	checkStore(11)
	srv.store = &networkBindingStore{Store: store.NewMemory(store.Config{}), requests: 23}
	srv.readCache = newTTLCache()
	checkStore(23)

	fleet := registry.New(logger)
	p := fleet.Register("replacement-fleet-provider", nil, &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "Apple M4 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "model"}},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.Attested = true
	p.Mu().Unlock()
	srv.registry = fleet
	srv.readCache = newTTLCache()
	var stats struct {
		Providers []struct {
			ID string `json:"id"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(read("/v1/stats"), &stats); err != nil {
		t.Fatal(err)
	}
	if len(stats.Providers) != 1 || stats.Providers[0].ID != p.ID {
		t.Fatalf("stats retained the prior fleet: %+v", stats.Providers)
	}

	for _, route := range []struct{ path, key string }{
		{"/v1/stats", "stats:v1"},
		{"/v1/network/totals", "network_totals:all"},
		{"/v1/network/series", "network_series:30m"},
		{"/v1/leaderboard", "leaderboard:earnings::50"},
	} {
		body := []byte(`{"cache":"` + route.key + `"}`)
		srv.readCache.Set(route.key, body, time.Minute)
		if got := read(route.path); !bytes.Equal(got, body) {
			t.Fatalf("%s did not serve the current shared cache: %s", route.path, got)
		}
	}
}
