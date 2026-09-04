package api

import (
	"context"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingAuthStore counts the two store reads the API-key miss path pays.
type countingAuthStore struct {
	store.Store
	authenticate  atomic.Int64
	providerToken atomic.Int64
}

func (c *countingAuthStore) AuthenticateKey(rawKey string) (*store.APIKey, error) {
	c.authenticate.Add(1)
	return c.Store.AuthenticateKey(rawKey)
}

func (c *countingAuthStore) GetProviderToken(token string) (*store.ProviderToken, error) {
	c.providerToken.Add(1)
	return c.Store.GetProviderToken(token)
}

func authCacheTestServer(t *testing.T) (*Server, *countingAuthStore, *httptest.Server) {
	t.Helper()
	inner := store.NewMemory(store.Config{AdminKey: "admin-test-key"})
	cst := &countingAuthStore{Store: inner}
	srv := NewServer(registry.New(quietLogger()), cst, ServerConfig{}, quietLogger())
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return srv, cst, ts
}

// authGet hits an authenticated read endpoint and returns the status code.
func authGet(t *testing.T, ts *httptest.Server, token string) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/payments/usage", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	_, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	return resp.StatusCode
}

func mintKeys(t *testing.T, st store.Store, n int) []string {
	t.Helper()
	keys := make([]string, 0, n)
	for i := 0; i < n; i++ {
		raw, _, err := st.CreateAPIKey(fmt.Sprintf("acct-%d", i), store.APIKeyCreate{Name: fmt.Sprintf("k%d", i)})
		if err != nil {
			t.Fatalf("CreateAPIKey: %v", err)
		}
		keys = append(keys, raw)
	}
	return keys
}

// TestAPIKeyCacheSurvivesUnknownTokenFlood: 50 valid keys primed, then 5,000
// distinct unknown tokens. The valid keys must still be served from the
// cache afterwards (no AuthenticateKey re-reads). Before the split, unknown
// tokens shared the 1,000-slot positive map and evicted every valid key.
func TestAPIKeyCacheSurvivesUnknownTokenFlood(t *testing.T) {
	srv, cst, ts := authCacheTestServer(t)
	keys := mintKeys(t, srv.store, 50)
	for _, k := range keys {
		if code := authGet(t, ts, k); code != http.StatusOK {
			t.Fatalf("prime: status %d", code)
		}
	}
	primed := cst.authenticate.Load()
	if primed != 50 {
		t.Fatalf("AuthenticateKey after priming = %d, want 50", primed)
	}

	for i := 0; i < 5000; i++ {
		if code := authGet(t, ts, fmt.Sprintf("not-a-key-%d", i)); code != http.StatusUnauthorized {
			t.Fatalf("unknown token %d: status %d, want 401", i, code)
		}
	}
	afterFlood := cst.authenticate.Load()
	if afterFlood != primed+5000 {
		t.Fatalf("AuthenticateKey after flood = %d, want %d (one per unknown token)", afterFlood, primed+5000)
	}

	for _, k := range keys {
		if code := authGet(t, ts, k); code != http.StatusOK {
			t.Fatalf("re-request: status %d", code)
		}
	}
	if got := cst.authenticate.Load(); got != afterFlood {
		t.Fatalf("valid keys re-read the DB after the flood: AuthenticateKey = %d, want %d", got, afterFlood)
	}
}

func TestAPIKeyCacheBoundsAndSeparatesNegatives(t *testing.T) {
	srv, _, ts := authCacheTestServer(t)
	keys := mintKeys(t, srv.store, 5)
	for _, k := range keys {
		authGet(t, ts, k)
	}
	for i := 0; i < 1000; i++ {
		authGet(t, ts, fmt.Sprintf("junk-%d", i))
	}
	srv.apiKeyCacheMu.RLock()
	pos, neg := len(srv.apiKeyCache), len(srv.apiKeyNegCache)
	srv.apiKeyCacheMu.RUnlock()
	if pos != 5 {
		t.Fatalf("positive map holds %d entries, want 5 (unknown tokens must not land here)", pos)
	}
	if neg > apiKeyNegCacheMaxSize {
		t.Fatalf("negative map holds %d entries, want <= %d", neg, apiKeyNegCacheMaxSize)
	}
}

// TestAPIKeyCachePrefixedUnknownTokenCostsOneStoreCall: an sk-db- token can
// never be a provider token, so its miss path is AuthenticateKey only; a
// prefix-less unknown token still falls through to GetProviderToken.
func TestAPIKeyCachePrefixedUnknownTokenCostsOneStoreCall(t *testing.T) {
	_, cst, ts := authCacheTestServer(t)

	if code := authGet(t, ts, store.KeyPrefix+"0123456789abcdef0123456789abcdef"); code != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", code)
	}
	if a, p := cst.authenticate.Load(), cst.providerToken.Load(); a != 1 || p != 0 {
		t.Fatalf("sk-db- unknown token: AuthenticateKey=%d GetProviderToken=%d, want 1/0", a, p)
	}
	// Repeat within the negative TTL: served from the negative map.
	authGet(t, ts, store.KeyPrefix+"0123456789abcdef0123456789abcdef")
	if a := cst.authenticate.Load(); a != 1 {
		t.Fatalf("negative hit re-read the DB: AuthenticateKey=%d", a)
	}

	if code := authGet(t, ts, "legacy-shaped-unknown-token"); code != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", code)
	}
	if a, p := cst.authenticate.Load(), cst.providerToken.Load(); a != 2 || p != 1 {
		t.Fatalf("prefix-less unknown token: AuthenticateKey=%d GetProviderToken=%d, want 2/1", a, p)
	}
}

func TestAPIKeyCacheNegativeExpiryAndInvalidation(t *testing.T) {
	srv, cst, ts := authCacheTestServer(t)

	// A token tried before its key exists is negative-cached, and becomes
	// usable once the negative entry ages out (no invalidation hook on
	// creation). Age it in place instead of sleeping.
	raw := store.KeyPrefix + "feedfacefeedfacefeedfacefeedface"
	if code := authGet(t, ts, raw); code != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", code)
	}
	hash := store.HashKey(raw)
	srv.apiKeyCacheMu.Lock()
	if _, ok := srv.apiKeyNegCache[hash]; !ok {
		srv.apiKeyCacheMu.Unlock()
		t.Fatal("unknown token was not negative-cached under its hash")
	}
	srv.apiKeyNegCache[hash] = time.Now().Add(-apiKeyNegCacheTTL - time.Second)
	srv.apiKeyCacheMu.Unlock()
	before := cst.authenticate.Load()
	authGet(t, ts, raw)
	if got := cst.authenticate.Load(); got != before+1 {
		t.Fatalf("expired negative entry did not re-read: AuthenticateKey=%d want %d", got, before+1)
	}

	// Revocation with the raw token invalidates the hashed positive entry.
	keys := mintKeys(t, srv.store, 1)
	if code := authGet(t, ts, keys[0]); code != http.StatusOK {
		t.Fatalf("status %d, want 200", code)
	}
	if !srv.store.RevokeKey(keys[0]) {
		t.Fatal("RevokeKey failed")
	}
	srv.invalidateAPIKeyCache(keys[0])
	if code := authGet(t, ts, keys[0]); code != http.StatusUnauthorized {
		t.Fatalf("revoked key still accepted: status %d", code)
	}

	// The generation bump drops both maps.
	authGet(t, ts, "junk-after-revoke")
	srv.invalidateAllAPIKeyCache()
	srv.apiKeyCacheMu.RLock()
	pos, neg := len(srv.apiKeyCache), len(srv.apiKeyNegCache)
	srv.apiKeyCacheMu.RUnlock()
	if pos != 0 || neg != 0 {
		t.Fatalf("after invalidateAll: positive=%d negative=%d, want 0/0", pos, neg)
	}
}

// TestAPIKeyCacheHoldsHashesNotRawTokens inspects both maps: every key is a
// 64-hex SHA-256 digest and none equals a raw token that was sent.
func TestAPIKeyCacheHoldsHashesNotRawTokens(t *testing.T) {
	srv, _, ts := authCacheTestServer(t)
	sent := mintKeys(t, srv.store, 3)
	sent = append(sent, "unknown-token-a", store.KeyPrefix+"deadbeefdeadbeefdeadbeefdeadbeef")
	for _, tok := range sent {
		authGet(t, ts, tok)
	}
	raw := map[string]bool{}
	for _, tok := range sent {
		raw[tok] = true
	}
	check := func(k string) {
		t.Helper()
		if raw[k] {
			t.Fatalf("raw token retained as a cache key")
		}
		if b, err := hex.DecodeString(k); err != nil || len(b) != 32 {
			t.Fatalf("cache key %q is not a SHA-256 hex digest", k)
		}
	}
	srv.apiKeyCacheMu.RLock()
	defer srv.apiKeyCacheMu.RUnlock()
	if len(srv.apiKeyCache) != 3 || len(srv.apiKeyNegCache) != 2 {
		t.Fatalf("maps hold %d/%d entries, want 3/2", len(srv.apiKeyCache), len(srv.apiKeyNegCache))
	}
	for k := range srv.apiKeyCache {
		check(k)
	}
	for k := range srv.apiKeyNegCache {
		check(k)
	}
}

// BenchmarkStoreAPIKeyCacheAtCapacity measures an insert into a full
// positive map: O(1) random eviction under the write lock (was a scan of
// all 1,000 entries for the oldest).
func BenchmarkStoreAPIKeyCacheAtCapacity(b *testing.B) {
	srv := &Server{apiKeyCache: make(map[string]apiKeyCacheEntry), apiKeyNegCache: make(map[string]time.Time)}
	for i := 0; i < apiKeyCacheMaxSize; i++ {
		srv.storeAPIKeyCache(store.HashKey(fmt.Sprintf("seed-%d", i)), apiKeyCacheEntry{key: &store.APIKey{}, cachedAt: time.Now()})
	}
	hashes := make([]string, 4096)
	for i := range hashes {
		hashes[i] = store.HashKey(fmt.Sprintf("bench-%d", i))
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		srv.storeAPIKeyCache(hashes[i%len(hashes)], apiKeyCacheEntry{key: &store.APIKey{}, cachedAt: time.Now()})
	}
}
