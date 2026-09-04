package api

// Stats refresher coverage: the request path is served from the cache the
// refresher owns; concurrent misses coalesce into one pipeline; a slow
// refresh serves the previous body (stale-while-refreshing); a failed or
// timed-out refresh never replaces a good body with an empty one; provider
// registration and catalog changes no longer evict the entry; and the
// Postgres-backed count of analytics executions per N requests.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// gatedAnalyticsStore forwards to a real store and counts the two refresher
// reads. It can hold an analytics call open (to observe stale-while-refreshing)
// or make either read fail the way a timeout does.
type gatedAnalyticsStore struct {
	store.Store
	analyticsCalls atomic.Int64
	totalsCalls    atomic.Int64
	failAnalytics  atomic.Bool
	failTotals     atomic.Bool
	panicAnalytics atomic.Bool // the read panics (a latent nil-map/row-shape bug)
	panicTotals    atomic.Bool

	mu      sync.Mutex
	hold    chan struct{} // when non-nil, analytics calls block until it is closed
	entered chan struct{} // receives one token per analytics call that reached the gate
}

func newGatedAnalyticsStore(inner store.Store) *gatedAnalyticsStore {
	return &gatedAnalyticsStore{Store: inner, entered: make(chan struct{}, 128)}
}

// arm makes subsequent analytics calls block until the returned release is called.
func (g *gatedAnalyticsStore) arm() (release func()) {
	g.mu.Lock()
	defer g.mu.Unlock()
	hold := make(chan struct{})
	g.hold = hold
	var once sync.Once
	return func() {
		once.Do(func() {
			g.mu.Lock()
			g.hold = nil
			g.mu.Unlock()
			close(hold)
		})
	}
}

func (g *gatedAnalyticsStore) UsageAnalyticsSince(ctx context.Context, since time.Time, locs map[string]*store.ProviderLocation) (store.UsageAnalytics, error) {
	g.analyticsCalls.Add(1)
	if g.panicAnalytics.Load() {
		panic("boom: analytics row shape")
	}
	if g.failAnalytics.Load() {
		return store.UsageAnalytics{}, context.DeadlineExceeded
	}
	g.mu.Lock()
	hold := g.hold
	g.mu.Unlock()
	if hold != nil {
		g.entered <- struct{}{}
		<-hold
	}
	return g.Store.UsageAnalyticsSince(ctx, since, locs)
}

func (g *gatedAnalyticsStore) NetworkTotals(since time.Time) (store.NetworkTotalsRow, error) {
	g.totalsCalls.Add(1)
	if g.panicTotals.Load() {
		panic("boom: totals scan")
	}
	if g.failTotals.Load() {
		return store.NetworkTotalsRow{}, context.DeadlineExceeded
	}
	return g.Store.NetworkTotals(since)
}

// expireFailureHoldForTest backdates every flight's last failure so the next
// call runs again — deterministic hold expiry without sleeping.
func (k *keyedFlights) expireFailureHoldForTest() {
	k.mu.Lock()
	defer k.mu.Unlock()
	for _, f := range k.m {
		f.mu.Lock()
		if !f.failedAt.IsZero() {
			f.failedAt = time.Now().Add(-2 * refreshFailureHold)
		}
		f.mu.Unlock()
	}
}

func newRefresherTestServer(t *testing.T, inner store.Store) (*Server, *gatedAnalyticsStore) {
	t.Helper()
	return newRefresherTestServerLogging(t, inner, io.Discard)
}

// newRefresherTestServerLogging is newRefresherTestServer with the server's
// log output directed at w (slog handlers serialize their writes).
func newRefresherTestServerLogging(t *testing.T, inner store.Store, w io.Writer) (*Server, *gatedAnalyticsStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(w, nil))
	st := newGatedAnalyticsStore(inner)
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	return srv, st
}

func getStats(t *testing.T, srv *Server) (int, []byte) {
	t.Helper()
	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	return rr.Code, rr.Body.Bytes()
}

func getNetworkTotals(t *testing.T, srv *Server, window string) (int, []byte) {
	t.Helper()
	rr := httptest.NewRecorder()
	srv.handleNetworkTotals(rr, httptest.NewRequest(http.MethodGet, "/v1/network/totals?window="+window, nil))
	return rr.Code, rr.Body.Bytes()
}

func seedUsage(st *store.MemoryStore, n int) {
	loc := &store.ProviderLocation{City: "New York", Region: "New York", RegionCode: "NY", Country: "United States", CountryCode: "US", Latitude: 40.7128, Longitude: -74.0060}
	for i := 0; i < n; i++ {
		st.RecordUsageWithCostAndLocation("provider-a", "consumer", "model", "", 10, 20, 0, loc)
	}
}

func concurrentStats(t *testing.T, srv *Server, n int) (codes []int, bodies [][]byte) {
	t.Helper()
	codes = make([]int, n)
	bodies = make([][]byte, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes[i], bodies[i] = getStats(t, srv)
		}()
	}
	wg.Wait()
	return codes, bodies
}

// While a refresh is in flight, every request is served the previous body
// and none of them starts a pipeline; the new body appears only once the
// refresh completes.
func TestStatsServesStaleWhileRefreshing(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 5)

	code, previous := getStats(t, srv)
	if code != http.StatusOK {
		t.Fatalf("warm status = %d: %s", code, previous)
	}
	if got := st.analyticsCalls.Load(); got != 1 {
		t.Fatalf("warm analytics calls = %d, want 1", got)
	}

	seedUsage(mem, 5) // the next body will differ (total_requests changes)
	release := st.arm()
	defer release()
	done := make(chan struct{})
	go func() {
		srv.refreshStatsCaches(context.Background())
		close(done)
	}()
	select {
	case <-st.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("refresh never reached the analytics query")
	}

	const n = 50
	codes, bodies := concurrentStats(t, srv, n)
	for i := 0; i < n; i++ {
		if codes[i] != http.StatusOK || !bytes.Equal(bodies[i], previous) {
			t.Fatalf("request %d during refresh: status %d, body changed=%v", i, codes[i], !bytes.Equal(bodies[i], previous))
		}
	}
	if got := st.analyticsCalls.Load(); got != 2 {
		t.Fatalf("analytics calls during refresh = %d, want 2 (warm + the in-flight tick)", got)
	}

	release()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("refresh did not complete after release")
	}
	code, fresh := getStats(t, srv)
	if code != http.StatusOK || bytes.Equal(fresh, previous) {
		t.Fatalf("post-refresh: status %d, body still the stale one=%v", code, bytes.Equal(fresh, previous))
	}
	if got := st.analyticsCalls.Load(); got != 2 {
		t.Fatalf("analytics calls after refresh = %d, want 2 (request path never computes)", got)
	}
	if got := st.totalsCalls.Load(); got != int64(len(networkTotalsWindows)) {
		t.Fatalf("network totals calls = %d, want one per window (%d)", got, len(networkTotalsWindows))
	}
	for _, w := range networkTotalsWindows {
		if _, ok := srv.readCache.Get(networkTotalsCacheKey(w)); !ok {
			t.Fatalf("network_totals:%s not populated by the tick", w)
		}
	}
}

// Fifty concurrent cold misses run exactly one pipeline and all receive its body.
func TestStatsColdMissesCoalesce(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 3)
	release := st.arm()
	defer release()

	const n = 50
	var (
		codes  = make([]int, n)
		bodies = make([][]byte, n)
		wg     sync.WaitGroup
	)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes[i], bodies[i] = getStats(t, srv)
		}()
	}
	select {
	case <-st.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("no request reached the analytics query")
	}
	// Give the other 49 a moment to pile up on the flight before releasing.
	time.Sleep(50 * time.Millisecond)
	release()
	wg.Wait()

	for i := 0; i < n; i++ {
		if codes[i] != http.StatusOK || !bytes.Equal(bodies[i], bodies[0]) {
			t.Fatalf("request %d: status %d, identical=%v", i, codes[i], bytes.Equal(bodies[i], bodies[0]))
		}
	}
	if got := st.analyticsCalls.Load(); got != 1 {
		t.Fatalf("analytics calls for %d cold misses = %d, want 1", n, got)
	}
}

// A refresh whose analytics query times out leaves the previous stats body
// in place; a NetworkTotals failure leaves the previous totals in place; with
// no previous body at all the handlers report unavailability instead of
// serving (and caching) an empty/zero result.
func TestStatsRefreshFailureKeepsPreviousBody(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 4)
	if err := mem.RecordProviderEarning(&store.ProviderEarning{AccountID: "acct", ProviderKey: "pk", JobID: "job-1", Model: "m", AmountMicroUSD: 1234, PromptTokens: 1, CompletionTokens: 2, CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	srv.refreshStatsCaches(context.Background())
	_, statsBefore := getStats(t, srv)
	_, totalsBefore := getNetworkTotals(t, srv, "24h")
	var totals struct {
		Earnings int64 `json:"earnings_micro_usd"`
	}
	if err := json.Unmarshal(totalsBefore, &totals); err != nil || totals.Earnings != 1234 {
		t.Fatalf("warm totals = %s (err %v)", totalsBefore, err)
	}

	st.failAnalytics.Store(true)
	st.failTotals.Store(true)
	seedUsage(mem, 4)
	calls := st.analyticsCalls.Load()
	srv.refreshStatsCaches(context.Background())
	if st.analyticsCalls.Load() != calls+1 {
		t.Fatal("failing refresh did not attempt the analytics query")
	}
	if code, body := getStats(t, srv); code != http.StatusOK || !bytes.Equal(body, statsBefore) {
		t.Fatalf("stats after failed refresh: status %d, previous body kept=%v", code, bytes.Equal(body, statsBefore))
	}
	if code, body := getNetworkTotals(t, srv, "24h"); code != http.StatusOK || !bytes.Equal(body, totalsBefore) {
		t.Fatalf("totals after failed refresh: status %d, previous body kept=%v", code, bytes.Equal(body, totalsBefore))
	}

	// No previous body and a failing store: unavailable, and nothing cached.
	srv.readCache.expireAllForTest()
	if code, body := getStats(t, srv); code != http.StatusServiceUnavailable {
		t.Fatalf("cold stats with failing analytics: status %d, body %s", code, body)
	}
	if code, body := getNetworkTotals(t, srv, "24h"); code != http.StatusServiceUnavailable {
		t.Fatalf("cold totals with failing store: status %d, body %s", code, body)
	}
	if _, ok := srv.readCache.Get(statsCacheKey); ok {
		t.Fatal("a failed cold refresh cached a stats body")
	}
	if _, ok := srv.readCache.Get(networkTotalsCacheKey("24h")); ok {
		t.Fatal("a failed cold refresh cached a totals body")
	}

	// Recovery: once the failure hold has expired, the next request
	// recomputes and serves the new data.
	st.failAnalytics.Store(false)
	st.failTotals.Store(false)
	srv.refreshFlights.expireFailureHoldForTest()
	if code, body := getStats(t, srv); code != http.StatusOK || bytes.Equal(body, statsBefore) {
		t.Fatalf("recovered stats: status %d, body unchanged=%v", code, bytes.Equal(body, statsBefore))
	}
	if code, _ := getNetworkTotals(t, srv, "24h"); code != http.StatusOK {
		t.Fatalf("recovered totals: status %d", code)
	}
}

// With nothing cached and a failing store, cold requests inside the failure
// hold do not stack pipelines: 50 concurrent misses run one execution, all
// answer 503, and a tick inside the hold runs nothing either; once the hold
// expires the next request executes again.
func TestStatsFailureHoldStopsPipelineStacking(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 2)
	st.failAnalytics.Store(true)
	st.failTotals.Store(true)

	const n = 50
	codes, _ := concurrentStats(t, srv, n)
	for i, code := range codes {
		if code != http.StatusServiceUnavailable {
			t.Fatalf("cold stats request %d during failure = %d, want 503", i, code)
		}
	}
	if got := st.analyticsCalls.Load(); got != 1 {
		t.Fatalf("analytics executions for %d cold misses on a failing store = %d, want 1", n, got)
	}
	var wg sync.WaitGroup
	totalsCodes := make([]int, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			totalsCodes[i], _ = getNetworkTotals(t, srv, "24h")
		}()
	}
	wg.Wait()
	for i, code := range totalsCodes {
		if code != http.StatusServiceUnavailable {
			t.Fatalf("cold totals request %d during failure = %d, want 503", i, code)
		}
	}
	if got := st.totalsCalls.Load(); got != 1 {
		t.Fatalf("totals executions for %d cold misses on a failing store = %d, want 1", n, got)
	}

	// A tick inside the hold runs nothing for the held keys (the other
	// windows, never attempted, run once each).
	srv.refreshStatsCaches(context.Background())
	if got := st.analyticsCalls.Load(); got != 1 {
		t.Fatalf("analytics executions after a tick inside the hold = %d, want 1", got)
	}
	if got := st.totalsCalls.Load(); got != int64(len(networkTotalsWindows)) {
		t.Fatalf("totals executions after a tick inside the hold = %d, want %d (24h held, other windows once)", got, len(networkTotalsWindows))
	}

	// Hold expired: the next request tries again.
	srv.refreshFlights.expireFailureHoldForTest()
	if code, _ := getStats(t, srv); code != http.StatusServiceUnavailable {
		t.Fatalf("stats after hold expiry with the store still failing = %d, want 503", code)
	}
	if got := st.analyticsCalls.Load(); got != 2 {
		t.Fatalf("analytics executions after hold expiry = %d, want 2", got)
	}
}

// A panic inside a build is contained by the refresh: it becomes that key's
// failure (previous body kept, failure hold set, cold requests inside the
// hold share the 503 without re-running the build), the flight is released
// for the next run, and it is logged like every other background panic.
// Before this fix the tick took the process down — and re-fired at boot.
func TestStatsRefreshRecoversBuildPanic(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	var logs bytes.Buffer
	srv, st := newRefresherTestServerLogging(t, mem, &logs)
	seedUsage(mem, 3)
	srv.refreshStatsCaches(context.Background())
	_, statsBefore := getStats(t, srv)
	_, totalsBefore := getNetworkTotals(t, srv, "24h")

	st.panicAnalytics.Store(true)
	st.panicTotals.Store(true)
	calls := st.analyticsCalls.Load()
	srv.refreshStatsCaches(context.Background()) // returns instead of crashing
	if got := st.analyticsCalls.Load(); got != calls+1 {
		t.Fatalf("analytics calls after the panicking tick = %d, want %d", got, calls+1)
	}
	if code, body := getStats(t, srv); code != http.StatusOK || !bytes.Equal(body, statsBefore) {
		t.Fatalf("stats after a panicking refresh: status %d, previous body kept=%v", code, bytes.Equal(body, statsBefore))
	}
	if code, body := getNetworkTotals(t, srv, "24h"); code != http.StatusOK || !bytes.Equal(body, totalsBefore) {
		t.Fatalf("totals after a panicking refresh: status %d, previous body kept=%v", code, bytes.Equal(body, totalsBefore))
	}
	logged := logs.String()
	for _, want := range []string{"panic in goroutine", "goroutine=stats_refresher.stats:v1", "goroutine=stats_refresher.network_totals:24h", "boom: analytics row shape", "boom: totals scan", "stack="} {
		if !strings.Contains(logged, want) {
			t.Fatalf("log missing %q:\n%s", want, logged)
		}
	}

	// The panic set the failure hold: cold misses inside it share the error
	// and do not re-run the (still panicking) build.
	srv.readCache.expireAllForTest()
	codes, _ := concurrentStats(t, srv, 50)
	for i, code := range codes {
		if code != http.StatusServiceUnavailable {
			t.Fatalf("cold stats request %d inside the hold = %d, want 503", i, code)
		}
	}
	if got := st.analyticsCalls.Load(); got != calls+1 {
		t.Fatalf("analytics calls after 50 cold misses inside the hold = %d, want %d", got, calls+1)
	}

	// The flight was released: once the hold expires and the bug is gone,
	// the next request recomputes.
	st.panicAnalytics.Store(false)
	st.panicTotals.Store(false)
	srv.refreshFlights.expireFailureHoldForTest()
	if code, _ := getStats(t, srv); code != http.StatusOK {
		t.Fatalf("stats after recovery = %d, want 200", code)
	}
	if code, _ := getNetworkTotals(t, srv, "24h"); code != http.StatusOK {
		t.Fatalf("totals after recovery = %d, want 200", code)
	}
}

// A cold miss whose refresh fails is a 503 that cannot succeed again inside
// the failure hold, so it carries Retry-After = the hold, on both endpoints.
func TestStatsUnavailableCarriesRetryAfter(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 1)
	st.failAnalytics.Store(true)
	st.failTotals.Store(true)

	want := strconv.Itoa(int(refreshFailureHold / time.Second))
	for _, path := range []string{"/v1/stats", "/v1/network/totals?window=24h"} {
		rr := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s: status %d, want 503", path, rr.Code)
		}
		if got := rr.Header().Get("Retry-After"); got != want {
			t.Fatalf("%s: Retry-After = %q, want %q", path, got, want)
		}
	}
}

type stubGeoResolver struct{ loc *store.ProviderLocation }

func (s stubGeoResolver) Lookup(*http.Request) *store.ProviderLocation { return s.loc }

// LookupAsync mirrors Lookup for the stub: the refresher tests only care that
// location resolution no longer evicts the stats entry.
func (s stubGeoResolver) LookupAsync(*http.Request) *store.ProviderLocation { return s.loc }

// Provider location resolution and catalog cache invalidation no longer evict
// the stats entry: the next request is still a cache hit and runs no pipeline.
func TestStatsEntrySurvivesProviderLocationAndCatalogInvalidation(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 2)
	_, warm := getStats(t, srv)

	srv.geoResolver = stubGeoResolver{loc: &store.ProviderLocation{City: "Austin", Region: "Texas", RegionCode: "TX", Country: "United States", CountryCode: "US"}}
	p := srv.registry.Register("prov-geo", nil, &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipFamily: "M3", ChipTier: "Max", MemoryGB: 64, GPUCores: 40},
		Models:   []protocol.ModelInfo{{ID: "mlx-community/gemma-4-26b-a4b-it-8bit"}},
	})
	srv.attachProviderLocation("prov-geo", p, httptest.NewRequest(http.MethodPost, "/ws/provider", nil))
	if p.Location == nil || p.Location.City != "Austin" {
		t.Fatalf("location not attached: %+v", p.Location)
	}
	srv.invalidateCatalogCache()

	if _, ok := srv.readCache.Get(statsCacheKey); !ok {
		t.Fatal("stats:v1 was evicted")
	}
	code, body := getStats(t, srv)
	if code != http.StatusOK || !bytes.Equal(body, warm) {
		t.Fatalf("post-registration stats: status %d, cache hit=%v", code, bytes.Equal(body, warm))
	}
	if got := st.analyticsCalls.Load(); got != 1 {
		t.Fatalf("analytics calls = %d, want 1 (no pipeline after registration)", got)
	}
}

// The refresher populates every owned key immediately at start (not after the
// first tick) and stops on context cancel.
func TestStatsRefresherRunsImmediatelyAndStops(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 1)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		srv.runStatsRefresher(ctx, testRefreshSchedule(time.Hour, time.Hour))
		close(done)
	}()
	deadline := time.After(5 * time.Second)
	for {
		_, statsOK := srv.readCache.Get(statsCacheKey)
		totalsOK := true
		for _, w := range networkTotalsWindows {
			if _, ok := srv.readCache.Get(networkTotalsCacheKey(w)); !ok {
				totalsOK = false
			}
		}
		if statsOK && totalsOK {
			break
		}
		select {
		case <-deadline:
			t.Fatal("refresher did not populate the owned keys at start")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	if st.analyticsCalls.Load() != 1 || st.totalsCalls.Load() != int64(len(networkTotalsWindows)) {
		t.Fatalf("calls at start: analytics %d totals %d", st.analyticsCalls.Load(), st.totalsCalls.Load())
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("refresher did not stop on context cancel")
	}
}

// testRefreshSchedule is a fast warm-up schedule: the provider count is
// sampled every 2 ms and fleet-driven refreshes are at least 10 ms apart.
func testRefreshSchedule(interval, warmupWindow time.Duration) statsRefreshSchedule {
	return statsRefreshSchedule{interval: interval, warmupWindow: warmupWindow, warmupPoll: 2 * time.Millisecond, warmupMinGap: 10 * time.Millisecond}
}

func registerStatsProvider(t *testing.T, srv *Server, id string) {
	t.Helper()
	srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipFamily: "M3", ChipTier: "Max", MemoryGB: 64, GPUCores: 40},
		Models:   []protocol.ModelInfo{{ID: "mlx-community/gemma-4-26b-a4b-it-8bit"}},
	})
}

// cachedActiveProviders reads active_providers from the cached stats body
// (-1 when nothing is cached).
func cachedActiveProviders(t *testing.T, srv *Server) int {
	t.Helper()
	body, ok := srv.readCache.Get(statsCacheKey)
	if !ok {
		return -1
	}
	var v struct {
		ActiveProviders int `json:"active_providers"`
	}
	if err := json.Unmarshal(body, &v); err != nil {
		t.Fatalf("decode cached stats: %v", err)
	}
	return v.ActiveProviders
}

func waitForActiveProviders(t *testing.T, srv *Server, want int, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for {
		if got := cachedActiveProviders(t, srv); got == want {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("cached active_providers = %d, want %d within %s", cachedActiveProviders(t, srv), want, within)
		}
		time.Sleep(time.Millisecond)
	}
}

// The boot refresh runs before any provider has reconnected, so its body says
// the network is empty. During the warm-up window the refresher follows the
// provider count: a provider that registers after the boot refresh is in
// the cached body within the warm-up gap (not at the next tick), only
// stats:v1 is recomputed (the totals windows do not read the registry), and
// registrations after the window fall back to the tick.
func TestStatsRefresherWarmupFollowsFleetReconnect(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	srv, st := newRefresherTestServer(t, mem)
	seedUsage(mem, 1)

	const warmupWindow = 400 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := time.Now()
	go srv.runStatsRefresher(ctx, testRefreshSchedule(time.Hour, warmupWindow))

	// Boot refresh: empty fleet.
	waitForActiveProviders(t, srv, 0, 5*time.Second)
	if got := st.analyticsCalls.Load(); got != 1 {
		t.Fatalf("analytics calls after the boot refresh = %d, want 1", got)
	}

	// The fleet reconnects after the boot refresh; the body follows it
	// within the warm-up gap. Before this fix it stayed at 0 until the tick.
	registerStatsProvider(t, srv, "warm-a")
	waitForActiveProviders(t, srv, 1, time.Second)
	registerStatsProvider(t, srv, "warm-b")
	registerStatsProvider(t, srv, "warm-c")
	waitForActiveProviders(t, srv, 3, time.Second)
	if got := st.totalsCalls.Load(); got != int64(len(networkTotalsWindows)) {
		t.Fatalf("totals calls = %d, want %d: fleet-driven refreshes must recompute stats:v1 only", got, len(networkTotalsWindows))
	}
	// Boot + one per fleet change, never more than one per gap.
	if got := st.analyticsCalls.Load(); got < 2 || got > 4 {
		t.Fatalf("analytics calls after three registrations = %d, want 2..4", got)
	}

	// After the window, a registration waits for the tick.
	if remaining := warmupWindow - time.Since(started); remaining > 0 {
		time.Sleep(remaining + 20*time.Millisecond)
	}
	calls := st.analyticsCalls.Load()
	registerStatsProvider(t, srv, "late-d")
	time.Sleep(50 * time.Millisecond)
	if got := cachedActiveProviders(t, srv); got != 3 {
		t.Fatalf("active_providers after the warm-up window = %d, want the tick-bound 3", got)
	}
	if got := st.analyticsCalls.Load(); got != calls {
		t.Fatalf("analytics calls after the warm-up window = %d, want %d (no fleet-driven refresh)", got, calls)
	}
}

// Measurement against real Postgres (DATABASE_URL, e.g. the docker
// perf-pg-bridge database): after one refresh, N concurrent public requests
// to /v1/stats and /v1/network/totals run ZERO analytics executions — the
// one refresh is the only pipeline. Logs the refresh wall time.
func TestStatsPipelineCountAgainstPostgres(t *testing.T) {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL-backed stats measurement")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pg, err := store.NewPostgres(ctx, store.Config{DatabaseURL: dbURL})
	if err != nil {
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(pg.Close)
	loc := &store.ProviderLocation{City: "New York", Region: "New York", RegionCode: "NY", Country: "United States", CountryCode: "US", Latitude: 40.7128, Longitude: -74.0060}
	for i := 0; i < 20; i++ {
		pg.RecordUsageWithCostAndLocation("prov-pgstats", "consumer", "model", "", 10, 20, 0, loc)
	}

	srv, st := newRefresherTestServer(t, pg)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	started := time.Now()
	srv.refreshStatsCaches(context.Background())
	t.Logf("loaded machine: one full refresh (stats + %d totals windows) took %s", len(networkTotalsWindows), time.Since(started))
	if st.analyticsCalls.Load() != 1 || st.totalsCalls.Load() != int64(len(networkTotalsWindows)) {
		t.Fatalf("refresh calls: analytics %d totals %d", st.analyticsCalls.Load(), st.totalsCalls.Load())
	}

	const n = 50
	var wg sync.WaitGroup
	var failures atomic.Int64
	for i := 0; i < n; i++ {
		for _, path := range []string{"/v1/stats", "/v1/network/totals?window=24h", "/v1/network/totals?window=all"} {
			wg.Add(1)
			go func() {
				defer wg.Done()
				resp, err := http.Get(ts.URL + path)
				if err != nil {
					failures.Add(1)
					return
				}
				_, _ = io.Copy(io.Discard, resp.Body)
				_ = resp.Body.Close()
				if resp.StatusCode != http.StatusOK {
					failures.Add(1)
				}
			}()
		}
	}
	wg.Wait()
	if failures.Load() != 0 {
		t.Fatalf("%d of %d requests failed", failures.Load(), 3*n)
	}
	if st.analyticsCalls.Load() != 1 || st.totalsCalls.Load() != int64(len(networkTotalsWindows)) {
		t.Fatalf("after %d requests: analytics executions %d (want 1), totals executions %d (want %d)",
			3*n, st.analyticsCalls.Load(), st.totalsCalls.Load(), len(networkTotalsWindows))
	}
}
