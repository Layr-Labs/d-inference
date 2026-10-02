package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestDesktopAccountTokenIsolationAndRevocation(t *testing.T) {
	srv, _ := testServer(t)
	digest := sha256.Sum256([]byte("desktop-test-token"))
	if err := srv.store.CreateProviderToken(&store.ProviderToken{TokenHash: hex.EncodeToString(digest[:]), AccountID: "desktop-owner", Active: true}); err != nil {
		t.Fatal(err)
	}
	for _, owner := range []string{"desktop-owner", "another-owner"} {
		if err := srv.store.UpsertProvider(context.Background(), store.ProviderRecord{ID: owner + "-node", AccountID: owner,
			Hardware: json.RawMessage(`{"chip_name":"Apple test","memory_gb":64}`), Models: json.RawMessage(`[]`),
			SEPublicKey: "secret-key-" + owner, LastSeen: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	read := func(token string) (int, string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/provider/desktop", nil)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(body)
	}
	if code, _ := read(""); code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated code=%d", code)
	}
	code, body := read("desktop-test-token")
	if code != http.StatusOK || !strings.Contains(body, "desktop-owner-node") {
		t.Fatalf("%d: %s", code, body)
	}
	for _, forbidden := range []string{"another-owner", "secret-key", "se_public_key", "provider_key", "system_volume_hash"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("leaked %s: %s", forbidden, body)
		}
	}
	if err := srv.store.RevokeProviderToken("desktop-test-token"); err != nil {
		t.Fatal(err)
	}
	if code, _ := read("desktop-test-token"); code != http.StatusUnauthorized {
		t.Fatalf("cached response survived revocation: %d", code)
	}
}

func TestDesktopMachineEarningsDoNotCrossAccountTransfers(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Now()
	for i, earning := range []store.ProviderEarning{
		{AccountID: "current-owner", ProviderKey: "shared-key", Model: "model", AmountMicroUSD: 40},
		{AccountID: "old-owner", ProviderKey: "shared-key", Model: "model", AmountMicroUSD: 900},
		{AccountID: "current-owner", ProviderKey: "shared-key", Model: "base_reward", AmountMicroUSD: 500},
	} {
		earning.CreatedAt = now.Add(-time.Minute)
		earning.JobID = string(rune('a' + i))
		if err := st.RecordProviderEarning(&earning); err != nil {
			t.Fatal(err)
		}
	}
	result := desktopUsageEarnings(context.Background(), store.NewCached(st, store.DefaultCacheConfig()), "current-owner", "shared-key", now)
	if result == nil || *result != "40" {
		t.Fatalf("account-scoped usage amount = %v, want 40", result)
	}
	if value := desktopUsageEarnings(context.Background(), st, "current-owner", "", now); value != nil {
		t.Fatal("missing attribution must remain unknown")
	}
}

// countingDesktopStore counts fleet reads; ListProvidersByAccount runs once
// per projection recompute (via mergeFleet).
type countingDesktopStore struct {
	store.Store
	listProviders atomic.Int64
}

func (c *countingDesktopStore) ListProvidersByAccount(ctx context.Context, accountID string) ([]store.ProviderRecord, error) {
	c.listProviders.Add(1)
	return c.Store.ListProvidersByAccount(ctx, accountID)
}

type desktopFixture struct {
	srv    *Server
	http   *httptest.Server
	counts *countingDesktopStore
}

// newDesktopFixture links two machines (SE keys se-key-a / se-key-b) to
// desktop-owner and mints one active provider token per entry in tokens.
func newDesktopFixture(t *testing.T, tokens ...string) desktopFixture {
	t.Helper()
	srv, _ := testServer(t)
	counts := &countingDesktopStore{Store: srv.store}
	srv.store = counts
	for _, token := range tokens {
		digest := sha256.Sum256([]byte(token))
		if err := srv.store.CreateProviderToken(&store.ProviderToken{TokenHash: hex.EncodeToString(digest[:]), AccountID: "desktop-owner", Active: true}); err != nil {
			t.Fatal(err)
		}
	}
	for _, node := range []string{"a", "b"} {
		if err := srv.store.UpsertProvider(context.Background(), store.ProviderRecord{ID: "node-" + node, AccountID: "desktop-owner",
			Hardware: json.RawMessage(`{"chip_name":"Apple test","memory_gb":64}`), Models: json.RawMessage(`[]`),
			SEPublicKey: "se-key-" + node, LastSeen: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	server := httptest.NewServer(srv.Handler())
	t.Cleanup(server.Close)
	return desktopFixture{srv: srv, http: server, counts: counts}
}

type desktopResult struct {
	code   int
	header http.Header
	body   string
}

func (f desktopFixture) get(token, identity string) (desktopResult, error) {
	req, err := http.NewRequest(http.MethodGet, f.http.URL+"/v1/provider/desktop", nil)
	if err != nil {
		return desktopResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if identity != "" {
		req.Header.Set("X-Darkbloom-Device-Identity", identity)
	}
	resp, err := f.http.Client().Do(req)
	if err != nil {
		return desktopResult{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	return desktopResult{code: resp.StatusCode, header: resp.Header, body: string(body)}, err
}

func (f desktopFixture) mustGet(t *testing.T, token, identity string) desktopResult {
	t.Helper()
	result, err := f.get(token, identity)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

// thisMacIDs decodes a 200 projection and returns the machine IDs flagged
// is_this_mac, failing on any SE key leaking into the response.
func thisMacIDs(result desktopResult) ([]string, error) {
	if result.code != http.StatusOK {
		return nil, fmt.Errorf("status %d: %s", result.code, result.body)
	}
	if strings.Contains(result.body, "se-key-") {
		return nil, fmt.Errorf("SE key leaked: %s", result.body)
	}
	var account desktopAccount
	if err := json.Unmarshal([]byte(result.body), &account); err != nil {
		return nil, err
	}
	if len(account.Machines) != 2 {
		return nil, fmt.Errorf("machines = %d, want 2: %s", len(account.Machines), result.body)
	}
	flagged := []string{}
	for _, machine := range account.Machines {
		if machine.IsThisMac {
			flagged = append(flagged, machine.ID)
		}
	}
	return flagged, nil
}

// The device identity header is client-controlled: varying it must not mint a
// new cache entry and re-run the fleet/earnings aggregation.
func TestDesktopAccountCacheIgnoresDeviceIdentityHeader(t *testing.T) {
	f := newDesktopFixture(t, "desktop-token")
	for _, identity := range []string{"se-key-a", "se-key-b", "", "random-1", "random-2", strings.Repeat("x", 4096)} {
		if result := f.mustGet(t, "desktop-token", identity); result.code != http.StatusOK {
			t.Fatalf("identity %.16q: status %d: %s", identity, result.code, result.body)
		}
	}
	if got := f.counts.listProviders.Load(); got != 1 {
		t.Fatalf("fleet recomputed %d times across identities, want 1 (per-account cache)", got)
	}
	if result := f.mustGet(t, "desktop-token", strings.Repeat("x", 4097)); result.code != http.StatusBadRequest {
		t.Fatalf("oversized identity status = %d, want 400", result.code)
	}
}

// is_this_mac is derived per request from the shared cached projection; run
// concurrently so -race exercises the shared value.
func TestDesktopAccountIsThisMacPerRequestFromCache(t *testing.T) {
	f := newDesktopFixture(t, "desktop-token")
	if _, err := thisMacIDs(f.mustGet(t, "desktop-token", "")); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"se-key-a": "node-a", "se-key-b": "node-b", "": "", "unknown-key": ""}
	type outcome struct {
		identity string
		flagged  []string
		err      error
	}
	outcomes := make(chan outcome, 4*len(want))
	var wg sync.WaitGroup
	for range 4 {
		for identity := range want {
			wg.Add(1)
			go func() {
				defer wg.Done()
				result, err := f.get("desktop-token", identity)
				if err == nil {
					var flagged []string
					flagged, err = thisMacIDs(result)
					outcomes <- outcome{identity: identity, flagged: flagged, err: err}
					return
				}
				outcomes <- outcome{identity: identity, err: err}
			}()
		}
	}
	wg.Wait()
	close(outcomes)
	for o := range outcomes {
		if o.err != nil {
			t.Fatalf("identity %q: %v", o.identity, o.err)
		}
		wantID := want[o.identity]
		if (wantID == "" && len(o.flagged) != 0) || (wantID != "" && (len(o.flagged) != 1 || o.flagged[0] != wantID)) {
			t.Fatalf("identity %q flagged %v, want %q", o.identity, o.flagged, wantID)
		}
	}
	if got := f.counts.listProviders.Load(); got != 1 {
		t.Fatalf("fleet recomputed %d times, want 1", got)
	}
}

// Revocation is checked before the cache: a warm per-account entry must not
// serve a revoked token under any identity.
func TestDesktopAccountRevocationCheckedBeforeCache(t *testing.T) {
	f := newDesktopFixture(t, "desktop-token")
	if result := f.mustGet(t, "desktop-token", "se-key-a"); result.code != http.StatusOK {
		t.Fatalf("warm status %d: %s", result.code, result.body)
	}
	if err := f.srv.store.RevokeProviderToken("desktop-token"); err != nil {
		t.Fatal(err)
	}
	for _, identity := range []string{"se-key-a", "se-key-b", ""} {
		if result := f.mustGet(t, "desktop-token", identity); result.code != http.StatusUnauthorized {
			t.Fatalf("revoked token identity %q: status %d, want 401", identity, result.code)
		}
	}
	key, err := f.srv.store.CreateKeyForAccount("desktop-owner")
	if err != nil {
		t.Fatal(err)
	}
	if result := f.mustGet(t, key, ""); result.code != http.StatusUnauthorized {
		t.Fatalf("consumer API key status %d, want 401", result.code)
	}
}

// The limit is keyed on the account, not the token: a second token for the
// same account draws from the same bucket.
func TestDesktopAccountRateLimitedPerAccount(t *testing.T) {
	f := newDesktopFixture(t, "desktop-token", "second-token")
	f.srv.SetRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))
	if result := f.mustGet(t, "desktop-token", ""); result.code != http.StatusOK {
		t.Fatalf("first status %d: %s", result.code, result.body)
	}
	result := f.mustGet(t, "second-token", "se-key-a")
	if result.code != http.StatusTooManyRequests || !strings.Contains(result.body, "rate_limit_exceeded") {
		t.Fatalf("over-limit status %d, want 429: %s", result.code, result.body)
	}
	if seconds, err := strconv.Atoi(result.header.Get("Retry-After")); err != nil || seconds < 1 {
		t.Fatalf("Retry-After = %q, want >= 1", result.header.Get("Retry-After"))
	}
}
