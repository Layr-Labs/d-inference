package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingStatsStore counts the usage analytics statements behind /v1/stats
// and can make them return nothing, the way the postgres store does on its
// 10 s statement timeout.
type countingStatsStore struct {
	store.Store
	locationCalls atomic.Int64
	flowCalls     atomic.Int64
	totalsCalls   atomic.Int64
	fail          atomic.Bool
	totalsFail    atomic.Bool
	// The four usage aggregates behind the /v1/stats headline figures report
	// failure explicitly (the postgres store used to fold a timeout into
	// zeros); each flag makes one of them fail.
	usageTotalsFail      atomic.Bool
	usageTotalsSinceFail atomic.Bool
	usageTimeSeriesFail  atomic.Bool
	usageCountFail       atomic.Bool
}

var errUsageStatementTimeout = errors.New("store: usage statement: timeout: context deadline exceeded")

func (c *countingStatsStore) UsageTotals() (store.UsageTotals, error) {
	if c.usageTotalsFail.Load() {
		return store.UsageTotals{}, errUsageStatementTimeout
	}
	return c.Store.UsageTotals()
}

func (c *countingStatsStore) UsageTotalsSince(since time.Time) (store.UsageTotals, error) {
	if c.usageTotalsSinceFail.Load() {
		return store.UsageTotals{}, errUsageStatementTimeout
	}
	return c.Store.UsageTotalsSince(since)
}

func (c *countingStatsStore) UsageTimeSeries(since, until time.Time, bucketSize time.Duration) ([]store.UsageBucket, error) {
	if c.usageTimeSeriesFail.Load() {
		return nil, errUsageStatementTimeout
	}
	return c.Store.UsageTimeSeries(since, until, bucketSize)
}

func (c *countingStatsStore) UsageCountSince(since time.Time) (int64, error) {
	if c.usageCountFail.Load() {
		return 0, errUsageStatementTimeout
	}
	return c.Store.UsageCountSince(since)
}

func (c *countingStatsStore) NetworkTotals(since time.Time) (store.NetworkTotalsRow, error) {
	c.totalsCalls.Add(1)
	if c.totalsFail.Load() {
		return store.NetworkTotalsRow{}, errors.New("store: network totals: timeout: context deadline exceeded")
	}
	return c.Store.NetworkTotals(since)
}

func (c *countingStatsStore) UsageLocationBuckets(since time.Time) []store.UsageLocationBucket {
	c.locationCalls.Add(1)
	if c.fail.Load() {
		return nil
	}
	return c.Store.UsageLocationBuckets(since)
}

func (c *countingStatsStore) UsageFlowBuckets(since time.Time, locs map[string]*store.ProviderLocation) []store.UsageFlowBucket {
	c.flowCalls.Add(1)
	if c.fail.Load() {
		return nil
	}
	return c.Store.UsageFlowBuckets(since, locs)
}

type staticGeoResolver struct{ loc *store.ProviderLocation }

func (g staticGeoResolver) Lookup(*http.Request) *store.ProviderLocation { return g.loc }

// newStatsRefresherFixture builds a server whose store has enough located
// usage and a located provider for both analytics statements to return rows,
// so a refresh produces a "good" value.
func newStatsRefresherFixture(t *testing.T) (*Server, *registry.Registry, *countingStatsStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	mem := store.NewMemory(store.Config{})
	st := &countingStatsStore{Store: mem}
	srv := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)

	sf := &store.ProviderLocation{
		City: "San Francisco", Region: "California", RegionCode: "CA",
		Country: "United States", CountryCode: "US",
		Latitude: 37.7749, Longitude: -122.4194, UpdatedAt: time.Now().UTC(),
	}
	nyc := &store.ProviderLocation{
		City: "New York", Region: "New York", RegionCode: "NY",
		Country: "United States", CountryCode: "US",
		Latitude: 40.7128, Longitude: -74.0060, UpdatedAt: time.Now().UTC(),
	}
	addProviderForStats(t, reg, "provider-sf", "hardware", sf)
	for i := 0; i < minRequestsPerCityBucket+2; i++ {
		mem.RecordUsageWithCostAndLocation("provider-sf", "consumer", "model", "req", 10, 20, 0, nyc)
	}
	return srv, reg, st
}

func statsBodyLocations(t *testing.T, body []byte) int {
	t.Helper()
	var parsed struct {
		RequestLocations []publicRequestLocationBucket `json:"request_locations"`
		RequestFlows     []publicRequestFlowBucket     `json:"request_flows"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		t.Fatalf("decode stats: %v", err)
	}
	if len(parsed.RequestFlows) == 0 {
		t.Fatalf("stats body has no request_flows: %s", body)
	}
	return len(parsed.RequestLocations)
}

func fireConcurrentStats(t *testing.T, url string, n int) {
	t.Helper()
	var wg sync.WaitGroup
	errs := make(chan string, n)
	for range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resp, err := http.Get(url)
			if err != nil {
				errs <- err.Error()
				return
			}
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				errs <- resp.Status
				return
			}
			if !bytes.Contains(body, []byte(`"request_locations":[{`)) {
				errs <- "response without request_locations: " + string(body[:min(len(body), 200)])
			}
		}()
	}
	wg.Wait()
	close(errs)
	for e := range errs {
		t.Fatalf("/v1/stats: %s", e)
	}
}

// TestStatsRefresherOwnsEntryUnderConcurrentRequests: with the refresher
// running, 50 concurrent /v1/stats requests are all served from the cache and
// add zero analytics statements; only the ticks compute.
func TestStatsRefresherOwnsEntryUnderConcurrentRequests(t *testing.T) {
	srv, _, st := newStatsRefresherFixture(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	const interval = 100 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.runStatsRefresher(ctx, interval)
	}()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if _, ok := srv.readCache.Get(statsCacheKey); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("refresher never cached stats:v1")
		}
		time.Sleep(5 * time.Millisecond)
	}

	before := st.locationCalls.Load()
	start := time.Now()
	fireConcurrentStats(t, ts.URL+"/v1/stats", 50)
	elapsed := time.Since(start)
	after := st.locationCalls.Load()
	// Every statement executed during the burst is attributable to a tick,
	// never to a handler: at most ceil(elapsed/interval)+1 of them.
	if maxTicks := int64(elapsed/interval) + 1; after-before > maxTicks {
		t.Fatalf("analytics statements during 50 concurrent requests = %d, want <= %d (handlers must not compute)", after-before, maxTicks)
	}

	// Ticks keep computing on their own cadence...
	time.Sleep(3 * interval)
	if got := st.locationCalls.Load(); got < before+2 {
		t.Fatalf("refresher ticks ran %d statements over 3 intervals, want >= 2", got-before)
	}
	// ...and stop with the context.
	cancel()
	<-done
	stopped := st.locationCalls.Load()
	time.Sleep(3 * interval)
	if got := st.locationCalls.Load(); got != stopped {
		t.Fatalf("statements after cancel = %d, want none", got-stopped)
	}
}

// TestStatsColdMissCoalescesConcurrentRequests: with no refresher and an empty
// cache, 50 concurrent requests share one computation.
func TestStatsColdMissCoalescesConcurrentRequests(t *testing.T) {
	srv, _, st := newStatsRefresherFixture(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	fireConcurrentStats(t, ts.URL+"/v1/stats", 50)
	if got := st.locationCalls.Load(); got != 1 {
		t.Fatalf("analytics statements for 50 concurrent cold misses = %d, want 1 (coalesced)", got)
	}
	if got := st.flowCalls.Load(); got != 1 {
		t.Fatalf("flow statements for 50 concurrent cold misses = %d, want 1 (coalesced)", got)
	}
	if _, ok := srv.readCache.Get(statsCacheKey); !ok {
		t.Fatal("cold miss did not populate stats:v1")
	}
}

// TestStatsRefreshKeepsPreviousValueWhenAnalyticsReturnNothing: a refresh
// whose analytics statements return nothing (store timeout) leaves the last
// good value in place; a degraded value is cached only when nothing better
// exists and is replaced by the next good refresh.
func TestStatsRefreshKeepsPreviousValueWhenAnalyticsReturnNothing(t *testing.T) {
	srv, _, st := newStatsRefresherFixture(t)

	good, ok := srv.refreshStats()
	if !ok || statsBodyLocations(t, good) == 0 {
		t.Fatalf("first refresh: ok=%v body=%s", ok, good)
	}

	st.fail.Store(true)
	served, ok := srv.refreshStats()
	if !ok {
		t.Fatal("degraded refresh reported failure")
	}
	if !bytes.Equal(served, good) {
		t.Fatalf("degraded refresh served a new body instead of the previous good one:\n%s", served)
	}
	cached, ok := srv.readCache.Get(statsCacheKey)
	if !ok || !bytes.Equal(cached, good) {
		t.Fatalf("degraded refresh replaced the cached good value (ok=%v)", ok)
	}
	if !srv.statsRefresh.haveGood {
		t.Fatal("haveGood cleared by a degraded refresh that kept the previous value")
	}

	// Handlers keep serving the good value while the store is failing.
	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK || !bytes.Equal(rr.Body.Bytes(), good) {
		t.Fatalf("handler during degraded refresh: code=%d body=%s", rr.Code, rr.Body.String())
	}

	// Cold cache + degraded result: nothing better exists, so it is cached
	// (short TTL) and flagged not-good; the next good refresh replaces it.
	srv.readCache.Invalidate(statsCacheKey)
	degraded, ok := srv.refreshStats()
	if !ok {
		t.Fatal("cold degraded refresh reported failure")
	}
	if cached, ok := srv.readCache.Get(statsCacheKey); !ok || !bytes.Equal(cached, degraded) {
		t.Fatal("cold degraded refresh did not cache its value")
	}
	if srv.statsRefresh.haveGood {
		t.Fatal("haveGood set by a degraded value")
	}
	st.fail.Store(false)
	recovered, ok := srv.refreshStats()
	if !ok || statsBodyLocations(t, recovered) == 0 {
		t.Fatalf("recovery refresh: ok=%v body=%s", ok, recovered)
	}
	if !srv.statsRefresh.haveGood {
		t.Fatal("haveGood not set after a good refresh")
	}
}

// TestStatsRefreshKeepsPreviousValueWhenUsageAggregateFails: the four usage
// aggregates behind the headline figures (lifetime totals, 24 h totals, the
// 30 min series, the 24 h request count) report failure explicitly, and any
// one failing marks the refresh degraded — so the last good value stays cached
// instead of a body with zero 24 h totals and a negative unknown-location
// count. The two analytics statements still return rows in every case here;
// before the fix that alone made the refresh count as good.
func TestStatsRefreshKeepsPreviousValueWhenUsageAggregateFails(t *testing.T) {
	srv, _, st := newStatsRefresherFixture(t)
	// One request without a location, so the good body carries a non-zero
	// unknown-location count that a failed window count would change.
	st.RecordUsageWithCostAndLocation("provider-sf", "consumer", "model", "req-unlocated", 10, 20, 0, nil)

	good, ok := srv.refreshStats()
	if !ok || statsBodyLocations(t, good) == 0 {
		t.Fatalf("first refresh: ok=%v body=%s", ok, good)
	}
	var goodParsed struct {
		Unknown int64 `json:"unknown_request_location_requests"`
	}
	if err := json.Unmarshal(good, &goodParsed); err != nil || goodParsed.Unknown != 1 {
		t.Fatalf("good body unknown_request_location_requests = %d (err=%v), want 1", goodParsed.Unknown, err)
	}

	cases := []struct {
		name string
		flag *atomic.Bool
	}{
		{"UsageTotals", &st.usageTotalsFail},
		{"UsageTotalsSince", &st.usageTotalsSinceFail},
		{"UsageTimeSeries", &st.usageTimeSeriesFail},
		{"UsageCountSince", &st.usageCountFail},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tc.flag.Store(true)
			defer tc.flag.Store(false)
			served, ok := srv.refreshStats()
			if !ok {
				t.Fatal("degraded refresh reported failure")
			}
			if !bytes.Equal(served, good) {
				t.Fatalf("refresh with a failing %s served a new body instead of the previous good one:\n%s", tc.name, served)
			}
			cached, ok := srv.readCache.Get(statsCacheKey)
			if !ok || !bytes.Equal(cached, good) {
				t.Fatalf("refresh with a failing %s replaced the cached good value (ok=%v)", tc.name, ok)
			}
			if !srv.statsRefresh.haveGood {
				t.Fatalf("haveGood cleared by a refresh with a failing %s", tc.name)
			}
		})
	}

	// Cold cache + failing count: the only value available is degraded and is
	// flagged so; it never carries a negative unknown-location count.
	st.usageCountFail.Store(true)
	defer st.usageCountFail.Store(false)
	srv.readCache.Invalidate(statsCacheKey)
	degraded, ok := srv.refreshStats()
	if !ok {
		t.Fatal("cold degraded refresh reported failure")
	}
	if srv.statsRefresh.haveGood {
		t.Fatal("haveGood set by a refresh whose request count failed")
	}
	var parsed struct {
		Unknown int64 `json:"unknown_request_location_requests"`
	}
	if err := json.Unmarshal(degraded, &parsed); err != nil {
		t.Fatalf("decode degraded stats: %v", err)
	}
	if parsed.Unknown < 0 {
		t.Fatalf("unknown_request_location_requests = %d with a failed count, want >= 0", parsed.Unknown)
	}
}

// TestProviderRegistrationNoLongerEvictsStats: resolving a provider location at
// registration and a catalog change used to evict stats:v1; the refresher now
// owns the entry, so both leave it in place.
func TestProviderRegistrationNoLongerEvictsStats(t *testing.T) {
	srv, reg, st := newStatsRefresherFixture(t)
	srv.geoResolver = staticGeoResolver{loc: &store.ProviderLocation{
		City: "Austin", Region: "Texas", RegionCode: "TX",
		Country: "United States", CountryCode: "US", Source: "test",
	}}

	good, ok := srv.refreshStats()
	if !ok {
		t.Fatal("refresh failed")
	}
	before := st.locationCalls.Load()

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
	if cached, ok := srv.readCache.Get(statsCacheKey); !ok || !bytes.Equal(cached, good) {
		t.Fatalf("provider registration evicted stats:v1 (ok=%v)", ok)
	}

	srv.invalidateCatalogCache()
	if cached, ok := srv.readCache.Get(statsCacheKey); !ok || !bytes.Equal(cached, good) {
		t.Fatalf("catalog invalidation evicted stats:v1 (ok=%v)", ok)
	}

	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d", rr.Code)
	}
	if got := st.locationCalls.Load(); got != before {
		t.Fatalf("handler recomputed stats after registration: %d extra statements", got-before)
	}
}

func seedNetworkEarnings(t *testing.T, st *countingStatsStore) {
	t.Helper()
	for i := range 3 {
		if err := st.RecordProviderEarning(&store.ProviderEarning{
			AccountID: "acct-totals", ProviderID: "provider-sf", ProviderKey: "key",
			JobID: "job-" + string(rune('a'+i)), Model: "model",
			AmountMicroUSD: 1_000, PromptTokens: 10, CompletionTokens: 20,
		}); err != nil {
			t.Fatalf("record earning: %v", err)
		}
	}
}

func decodeTotals(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode totals: %v (%s)", err, body)
	}
	return out
}

// TestNetworkTotalsRefreshKeepsPreviousValueOnStoreError: a NetworkTotals
// error (the store timeout that used to come back as an all-zero row) leaves
// the cached totals unchanged and the handler keeps serving them; with
// nothing cached the handler answers 503 rather than caching zeros.
func TestNetworkTotalsRefreshKeepsPreviousValueOnStoreError(t *testing.T) {
	srv, _, st := newStatsRefresherFixture(t)
	seedNetworkEarnings(t, st)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	get := func(window string) (int, []byte) {
		t.Helper()
		resp, err := http.Get(ts.URL + "/v1/network/totals?window=" + window)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, body
	}

	code, good := get("all")
	if code != http.StatusOK {
		t.Fatalf("status = %d body = %s", code, good)
	}
	if totals := decodeTotals(t, good); totals["earnings_micro_usd"].(float64) != 3_000 || totals["jobs"].(float64) != 3 {
		t.Fatalf("seeded totals = %v", totals)
	}

	st.totalsFail.Store(true)
	served, ok := srv.refreshNetworkTotals("all")
	if !ok || !bytes.Equal(served, good) {
		t.Fatalf("refresh during store error: ok=%v served=%s", ok, served)
	}
	if cached, ok := srv.readCache.Get(networkTotalsCacheKey("all")); !ok || !bytes.Equal(cached, good) {
		t.Fatalf("store error replaced the cached totals (ok=%v): %s", ok, cached)
	}
	if code, body := get("all"); code != http.StatusOK || !bytes.Equal(body, good) {
		t.Fatalf("handler during store error: code=%d body=%s", code, body)
	}

	// Nothing cached + store error: no zero row is cached or served.
	srv.readCache.Invalidate(networkTotalsCacheKey("all"))
	if code, body := get("all"); code != http.StatusServiceUnavailable {
		t.Fatalf("cold miss during store error: code=%d body=%s, want 503", code, body)
	}
	if _, ok := srv.readCache.Get(networkTotalsCacheKey("all")); ok {
		t.Fatal("a failed refresh cached a value")
	}

	st.totalsFail.Store(false)
	code, recovered := get("all")
	if code != http.StatusOK || decodeTotals(t, recovered)["jobs"].(float64) != 3 {
		t.Fatalf("recovery: code=%d body=%s", code, recovered)
	}
}

// TestNetworkTotalsRefresherOwnsEveryWindow: the refresher keeps all four
// canonical windows warm; aliases (1d, lifetime, "") are served from the
// canonical entries, and handlers add no statements of their own.
func TestNetworkTotalsRefresherOwnsEveryWindow(t *testing.T) {
	srv, _, st := newStatsRefresherFixture(t)
	seedNetworkEarnings(t, st)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.runNetworkTotalsRefresher(ctx, time.Hour)
	deadline := time.Now().Add(3 * time.Second)
	for _, window := range networkTotalsWindows {
		for {
			if _, ok := srv.readCache.Get(networkTotalsCacheKey(window)); ok {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("refresher never cached window %q", window)
			}
			time.Sleep(5 * time.Millisecond)
		}
	}
	if got := st.totalsCalls.Load(); got != int64(len(networkTotalsWindows)) {
		t.Fatalf("statements for one refresh pass = %d, want %d", got, len(networkTotalsWindows))
	}

	before := st.totalsCalls.Load()
	for param, want := range map[string]string{"": "all", "lifetime": "all", "1d": "24h", "24h": "24h", "7d": "7d", "30d": "30d", "all": "all"} {
		resp, err := http.Get(ts.URL + "/v1/network/totals?window=" + param)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("window %q: status %d body %s", param, resp.StatusCode, body)
		}
		if got := decodeTotals(t, body)["window"]; got != want {
			t.Fatalf("window %q served body window %v, want %q", param, got, want)
		}
	}
	if got := st.totalsCalls.Load(); got != before {
		t.Fatalf("handlers ran %d statements while the refresher owns the entries", got-before)
	}
}
