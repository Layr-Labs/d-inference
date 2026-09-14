package api

import (
	"bytes"

	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"

	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type registrationStatsStore struct {
	store.Store
	locationCalls atomic.Int64
	coreCalls     atomic.Int64
}

func (s *registrationStatsStore) UsageTotals() (store.UsageTotals, error) {
	s.coreCalls.Add(1)
	return s.Store.UsageTotals()
}
func (s *registrationStatsStore) UsageLocationBuckets(since time.Time) ([]store.UsageLocationBucket, error) {
	s.locationCalls.Add(1)
	return s.Store.UsageLocationBuckets(since)
}

type staticGeoResolver struct{ loc *store.ProviderLocation }

func (g staticGeoResolver) Lookup(*http.Request) *store.ProviderLocation { return g.loc }

// TestProviderRegistrationNoLongerEvictsStats: resolving a provider location at
// registration and a catalog change used to evict stats:v1; the refresher now
// owns the entry, so both leave it in place.
func TestProviderRegistrationNoLongerEvictsStats(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	st := &registrationStatsStore{Store: store.NewMemory(store.Config{})}
	srv := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.geoResolver = staticGeoResolver{loc: &store.ProviderLocation{
		City: "Austin", Region: "Texas", RegionCode: "TX",
		Country: "United States", CountryCode: "US", Source: "test",
	}}

	prime := httptest.NewRecorder()
	srv.Handler().ServeHTTP(prime, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if prime.Code != http.StatusOK {
		t.Fatalf("prime stats: %d %s", prime.Code, prime.Body.String())
	}
	good := prime.Body.Bytes()
	before := st.locationCalls.Load()
	beforeCore := st.coreCalls.Load()

	p := reg.Register("provider-new", nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", Version: "1.0.0",
		Hardware: protocol.Hardware{ChipName: "Apple M4 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "model"}},
	})
	srv.attachProviderLocation(p.ID, p, httptest.NewRequest(http.MethodGet, "/ws/provider", nil))
	p.Mu().Lock()
	resolved := p.Location != nil && p.Location.City == "Austin"
	p.Mu().Unlock()
	if !resolved {
		t.Fatal("attachProviderLocation did not resolve the location (test did not exercise the eviction site)")
	}
	if cached, ok := srv.readCache.Get("stats:v1"); !ok || !bytes.Equal(cached, good) {
		t.Fatalf("provider registration evicted stats:v1 (ok=%v)", ok)
	}

	srv.invalidateCatalogCache()
	if cached, ok := srv.readCache.Get("stats:v1"); !ok || !bytes.Equal(cached, good) {
		t.Fatalf("catalog invalidation evicted stats:v1 (ok=%v)", ok)
	}

	rr := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d", rr.Code)
	}
	if got := st.locationCalls.Load(); got != before {
		t.Fatalf("handler recomputed stats after registration: %d extra statements", got-before)
	}
	if got := st.coreCalls.Load(); got != beforeCore {
		t.Fatalf("handler recomputed core stats after registration: %d extra statements", got-beforeCore)
	}
}
