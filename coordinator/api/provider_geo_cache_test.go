package api

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// geoStub is an in-process ip-api.com: it counts calls, optionally blocks
// every request until release is closed, and answers with body.
type geoStub struct {
	ts      *httptest.Server
	calls   atomic.Int64
	release chan struct{}
	body    string
}

func newGeoStub(t *testing.T, body string, block bool) *geoStub {
	t.Helper()
	st := &geoStub{body: body}
	if block {
		st.release = make(chan struct{})
	}
	st.ts = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		st.calls.Add(1)
		if st.release != nil {
			<-st.release
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, st.body)
	}))
	t.Cleanup(st.ts.Close)
	return st
}

func (st *geoStub) resolver() *ipAPIGeoResolver {
	return &ipAPIGeoResolver{baseURL: st.ts.URL, httpClient: st.ts.Client()}
}

// geoRequest builds a request as the coordinator sees it behind Caddy: a
// loopback RemoteAddr (trusted proxy) with the public client IP in XFF.
func geoRequest(clientIP string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	r.RemoteAddr = "127.0.0.1:43210"
	r.Header.Set("X-Forwarded-For", clientIP)
	return r
}

func TestGeoLookupAsyncOneNetworkCallPerIP(t *testing.T) {
	stub := newGeoStub(t, ipAPISuccessBody, false)
	g := stub.resolver()

	// First request from the IP: a miss answers nil immediately and fills in
	// the background.
	if loc := g.LookupAsync(geoRequest("8.8.8.8")); loc != nil {
		t.Fatalf("first LookupAsync = %#v, want nil (async fill)", loc)
	}
	if !waitForCond(5*time.Second, func() bool { _, ok := g.cached("8.8.8.8"); return ok }) {
		t.Fatal("async fill never populated the cache")
	}
	// 100 sequential requests from the same IP: every one is a cache hit.
	for i := 0; i < 100; i++ {
		loc := g.LookupAsync(geoRequest("8.8.8.8"))
		if loc == nil || loc.City != "Mountain View" || loc.Source != "ip-api" {
			t.Fatalf("request %d: LookupAsync = %#v, want cached Mountain View", i, loc)
		}
	}
	if got := stub.calls.Load(); got != 1 {
		t.Fatalf("ip-api calls = %d, want exactly 1 for 101 requests from one IP", got)
	}
	// Returned locations are copies: mutating one must not poison the cache.
	loc := g.LookupAsync(geoRequest("8.8.8.8"))
	loc.City = "mutated"
	if again := g.LookupAsync(geoRequest("8.8.8.8")); again.City != "Mountain View" {
		t.Fatalf("cache returned a shared pointer: City = %q", again.City)
	}
}

func TestGeoLookupAsyncNeverBlocksOnSlowLookup(t *testing.T) {
	stub := newGeoStub(t, ipAPISuccessBody, true)
	g := stub.resolver()

	start := time.Now()
	loc := g.LookupAsync(geoRequest("1.1.1.1"))
	elapsed := time.Since(start)
	if loc != nil {
		t.Fatalf("LookupAsync = %#v, want nil while the lookup is in flight", loc)
	}
	// A blocked ip-api must not be felt on the request goroutine (the old
	// synchronous path waited the full 3 s client timeout here).
	if elapsed > 200*time.Millisecond {
		t.Fatalf("LookupAsync took %v with a blocked ip-api, want ~0", elapsed)
	}
	// While the fill is in flight, repeat misses are deduplicated: no second
	// network call is started for the same IP.
	for i := 0; i < 10; i++ {
		_ = g.LookupAsync(geoRequest("1.1.1.1"))
	}
	if !waitForCond(2*time.Second, func() bool { return stub.calls.Load() == 1 }) {
		t.Fatalf("stub calls = %d, want 1 (in-flight dedupe)", stub.calls.Load())
	}
	close(stub.release)
	if !waitForCond(5*time.Second, func() bool { _, ok := g.cached("1.1.1.1"); return ok }) {
		t.Fatal("fill never completed after release")
	}
	if got := stub.calls.Load(); got != 1 {
		t.Fatalf("stub calls = %d after fill, want 1", got)
	}
}

func TestGeoLookupAsyncCachesNegativeResultsUntilTTL(t *testing.T) {
	stub := newGeoStub(t, `{"status":"fail","message":"reserved range"}`, false)
	g := stub.resolver()
	now := time.Now()
	g.now = func() time.Time { return now }

	_ = g.LookupAsync(geoRequest("9.9.9.9"))
	if !waitForCond(5*time.Second, func() bool { _, ok := g.cached("9.9.9.9"); return ok }) {
		t.Fatal("negative fill never landed")
	}
	// Negative entry: repeat requests neither block nor re-query.
	for i := 0; i < 50; i++ {
		if loc := g.LookupAsync(geoRequest("9.9.9.9")); loc != nil {
			t.Fatalf("negative hit returned %#v", loc)
		}
	}
	if got := stub.calls.Load(); got != 1 {
		t.Fatalf("stub calls = %d, want 1 while the negative entry is live", got)
	}
	// Past the negative TTL the next request re-queries.
	now = now.Add(geoCacheNegativeTTL)
	_ = g.LookupAsync(geoRequest("9.9.9.9"))
	if !waitForCond(5*time.Second, func() bool { return stub.calls.Load() == 2 }) {
		t.Fatalf("stub calls = %d after negative TTL, want 2", stub.calls.Load())
	}
}

func TestGeoLookupPositiveEntryExpiresAfterTTL(t *testing.T) {
	stub := newGeoStub(t, ipAPISuccessBody, false)
	g := stub.resolver()
	now := time.Now()
	g.now = func() time.Time { return now }

	if loc := g.Lookup(geoRequest("8.8.4.4")); loc == nil {
		t.Fatal("sync Lookup returned nil")
	}
	now = now.Add(geoCachePositiveTTL - time.Second)
	if loc := g.LookupAsync(geoRequest("8.8.4.4")); loc == nil {
		t.Fatal("entry expired before its TTL")
	}
	now = now.Add(2 * time.Second)
	if loc := g.LookupAsync(geoRequest("8.8.4.4")); loc != nil {
		t.Fatalf("expired entry still served: %#v", loc)
	}
	if !waitForCond(5*time.Second, func() bool { return stub.calls.Load() == 2 }) {
		t.Fatalf("stub calls = %d after positive TTL, want 2", stub.calls.Load())
	}
}

func TestGeoLookupAsyncBoundsInflightFills(t *testing.T) {
	stub := newGeoStub(t, ipAPISuccessBody, true)
	g := stub.resolver()

	const distinct = geoLookupMaxInflight + 36
	for i := 0; i < distinct; i++ {
		_ = g.LookupAsync(geoRequest(fmt.Sprintf("8.8.%d.%d", i/256, i%256+1)))
	}
	if got := g.asyncDropped.Load(); got != 36 {
		t.Fatalf("asyncDropped = %d, want 36 (%d distinct IPs over a %d in-flight cap)", got, distinct, geoLookupMaxInflight)
	}
	if !waitForCond(5*time.Second, func() bool { return stub.calls.Load() == geoLookupMaxInflight }) {
		t.Fatalf("stub calls = %d, want %d", stub.calls.Load(), geoLookupMaxInflight)
	}
	close(stub.release)
	if !waitForCond(5*time.Second, func() bool { return g.cacheLen() == geoLookupMaxInflight }) {
		t.Fatalf("cacheLen = %d, want %d", g.cacheLen(), geoLookupMaxInflight)
	}
	// Capacity freed: a fresh miss fills again.
	_ = g.LookupAsync(geoRequest("8.9.0.1"))
	if !waitForCond(5*time.Second, func() bool { return stub.calls.Load() == geoLookupMaxInflight+1 }) {
		t.Fatalf("stub calls = %d after the burst drained, want %d", stub.calls.Load(), geoLookupMaxInflight+1)
	}
}

func TestGeoCacheEvictsWhenFull(t *testing.T) {
	g := &ipAPIGeoResolver{}
	for i := 0; i < geoCacheMaxEntries+100; i++ {
		g.storeResult(fmt.Sprintf("ip-%d", i), nil)
	}
	if got := g.cacheLen(); got != geoCacheMaxEntries {
		t.Fatalf("cacheLen = %d, want bound %d", got, geoCacheMaxEntries)
	}
}

func TestGeoSyncLookupPopulatesSharedCacheAndProviderLocation(t *testing.T) {
	stub := newGeoStub(t, ipAPISuccessBody, false)
	srv, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	g := stub.resolver()
	srv.geoResolver = g

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: "geo-model", ModelType: "chat"}}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")
	ids := reg.ProviderIDs()
	if len(ids) == 0 {
		t.Fatal("no provider registered")
	}
	p := reg.GetProvider(ids[0])

	// Registration resolves synchronously: the Provider carries its location
	// as soon as attachProviderLocation returns.
	srv.attachProviderLocation(ids[0], p, geoRequest("8.8.8.8"))
	p.Mu().Lock()
	loc := p.Location
	p.Mu().Unlock()
	if loc == nil || loc.City != "Mountain View" || loc.Source != "ip-api" {
		t.Fatalf("provider Location = %#v, want synchronous Mountain View", loc)
	}
	// The consumer path shares the cache: same IP, no second network call,
	// and the request_ prefix is applied to the copy only.
	got := srv.requestLocation(geoRequest("8.8.8.8"))
	if got == nil || got.Source != "request_ip-api" || got.City != "Mountain View" {
		t.Fatalf("requestLocation = %#v, want cached request_ip-api", got)
	}
	if calls := stub.calls.Load(); calls != 1 {
		t.Fatalf("stub calls = %d, want 1 shared by registration and request paths", calls)
	}
	if cached, _ := g.cached("8.8.8.8"); cached.Source != "ip-api" {
		t.Fatalf("cache Source = %q, want un-prefixed ip-api", cached.Source)
	}
}

func TestLookupIPAPIRedactsProKeyFromErrorLog(t *testing.T) {
	const secret = "super-secret-pro-key-42"
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	// A closed listener: the client error is a *url.Error wrapping a dial
	// failure, whose Error() text embeds the full keyed URL.
	closed := httptest.NewServer(http.NotFoundHandler())
	base := closed.URL
	closed.Close()
	g := &ipAPIGeoResolver{apiKey: secret, baseURL: base, logger: logger, httpClient: &http.Client{Timeout: time.Second}}
	if loc := g.lookupIPAPI(net.ParseIP("8.8.8.8")); loc != nil {
		t.Fatalf("lookup against a closed port returned %#v", loc)
	}
	out := buf.String()
	if !strings.Contains(out, "ip-api lookup failed") {
		t.Fatalf("expected the failure to be logged, got %q", out)
	}
	if strings.Contains(out, secret) {
		t.Fatalf("PRO key leaked into the log line: %q", out)
	}
	if strings.Contains(out, "key=") {
		t.Fatalf("keyed URL leaked into the log line: %q", out)
	}
}

// TestSecondRequestFromIPCarriesRequestLocation drives two real chat
// completions through the server and an in-process provider: the first
// request from a client IP is admitted before the geo fill lands (no location
// on its usage row, and no wait on ip-api), the second carries the cached
// location with the request_ source prefix.
func TestSecondRequestFromIPCarriesRequestLocation(t *testing.T) {
	stub := newGeoStub(t, ipAPISuccessBody, false)
	srv, st, _ := billingTestServer(t)
	g := stub.resolver()
	srv.geoResolver = g
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	model := "geo-usage-model"
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5}

	send := func() {
		t.Helper()
		body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true}`
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		req.Header.Set("X-Forwarded-For", "8.8.8.8")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		_, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
	}

	done := serveOneInference(ctx, t, conn, pubKey, usage)
	send()
	<-done
	if !waitForCond(5*time.Second, func() bool { return len(st.UsageByConsumer(testConsumerID)) == 1 }) {
		t.Fatal("first usage row never landed")
	}
	if rows := st.UsageByConsumer(testConsumerID); rows[0].RequestLocation != nil {
		t.Fatalf("first request from the IP carried a location %#v; the fill is asynchronous", rows[0].RequestLocation)
	}
	if !waitForCond(5*time.Second, func() bool { _, ok := g.cached("8.8.8.8"); return ok }) {
		t.Fatal("geo fill never landed")
	}

	done = serveOneInference(ctx, t, conn, pubKey, usage)
	send()
	<-done
	if !waitForCond(5*time.Second, func() bool { return len(st.UsageByConsumer(testConsumerID)) == 2 }) {
		t.Fatal("second usage row never landed")
	}
	var second *store.ProviderLocation
	for _, row := range st.UsageByConsumer(testConsumerID) {
		if row.RequestLocation != nil {
			second = row.RequestLocation
		}
	}
	if second == nil || second.City != "Mountain View" || second.Source != "request_ip-api" {
		t.Fatalf("second usage row location = %#v, want request_ip-api Mountain View", second)
	}
	if calls := stub.calls.Load(); calls != 1 {
		t.Fatalf("stub calls = %d for two requests from one IP, want 1", calls)
	}
}
