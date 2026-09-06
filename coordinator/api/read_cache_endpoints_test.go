package api

// Read-cache coverage for the public catalog/trust endpoints, through the
// real HTTP path: a repeat request within the TTL is served without
// recomputing (store read counters stay flat, bytes identical), a mutation
// inside the TTL is not yet visible, expiry recomputes, and per-caller views
// (self-route owned models, key allow-lists) bypass the shared cache.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// catalogReadCountingStore wraps the real memory store and counts the DB reads the
// cached catalog endpoints depend on.
type catalogReadCountingStore struct {
	store.Store
	aliases  atomic.Int64
	registry atomic.Int64
}

func (c *catalogReadCountingStore) ListModelAliases() ([]store.ModelAlias, error) {
	c.aliases.Add(1)
	return c.Store.ListModelAliases()
}

func (c *catalogReadCountingStore) ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error) {
	c.registry.Add(1)
	return c.Store.ListActiveModelRegistryWithError()
}

func (c *catalogReadCountingStore) reads() int64 { return c.aliases.Load() + c.registry.Load() }

// expireAllForTest backdates every entry so the next lookup misses —
// deterministic TTL expiry without sleeping.
func (c *ttlCache) expireAllForTest() {
	c.mu.Lock()
	for k, e := range c.data {
		e.expiresAt = time.Now().Add(-time.Second)
		c.data[k] = e
	}
	c.mu.Unlock()
}

type cachedEndpointHarness struct {
	srv *Server
	reg *registry.Registry
	mem *store.MemoryStore
	st  *catalogReadCountingStore
	ts  *httptest.Server
}

func newCachedEndpointHarness(t *testing.T) *cachedEndpointHarness {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	mem := store.NewMemory(store.Config{AdminKey: "test-key"})
	st := &catalogReadCountingStore{Store: mem}
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 500 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &cachedEndpointHarness{srv: srv, reg: reg, mem: mem, st: st, ts: ts}
}

// seedCatalogModel registers an active catalog model with platform pricing
// and syncs the routing catalog.
func (h *cachedEndpointHarness) seedCatalogModel(t *testing.T, modelID string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID:               modelID,
		DisplayName:      modelID + " display",
		Family:           "test",
		Quantization:     "4bit",
		MaxContextLength: 8192,
		MaxOutputLength:  1024,
		MinRAMGB:         8,
		Capabilities:     []string{"tools"},
		Status:           "active",
		CreatedAt:        time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC),
	}
	version := &store.ModelVersion{ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := h.mem.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := h.mem.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatal(err)
	}
	h.srv.SyncModelCatalog()
	if err := h.mem.SetModelPrice("platform", modelID, 50_000, 200_000); err != nil {
		t.Fatal(err)
	}
}

// connectProvider connects a routable provider serving modelID and keeps it
// answering attestation challenges for the life of the test.
func (h *cachedEndpointHarness) connectProvider(t *testing.T, ctx context.Context, modelID string) *websocket.Conn {
	t.Helper()
	pubKey := testPublicKeyB64()
	conn := connectAndPrepareProvider(t, ctx, h.ts.URL, h.reg, modelID, pubKey, 50.0)
	go handleProviderMessages(ctx, t, conn, func(msgType string, data []byte) []byte {
		if msgType == protocol.TypeAttestationChallenge {
			return makeValidChallengeResponse(data, pubKey)
		}
		return nil
	})
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })
	return conn
}

func (h *cachedEndpointHarness) get(t *testing.T, ctx context.Context, path, bearer string) (int, []byte) {
	t.Helper()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, h.ts.URL+path, nil)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

func mustOK(t *testing.T, status int, body []byte) {
	t.Helper()
	if status != http.StatusOK {
		t.Fatalf("status = %d body = %s", status, body)
	}
}

func modelIDs(t *testing.T, body []byte) []string {
	t.Helper()
	var resp types.ModelListResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("decode model list: %v\n%s", err, body)
	}
	ids := make([]string, 0, len(resp.Data))
	for _, m := range resp.Data {
		ids = append(ids, m.ID)
	}
	return ids
}

func containsID(ids []string, id string) bool {
	for _, v := range ids {
		if v == id {
			return true
		}
	}
	return false
}

// GET /v1/models: a repeat within the TTL is byte-identical and skips the
// store; a provider that connects inside the TTL is not visible until the
// entry expires, after which the list is recomputed.
func TestModelsListCache_RepeatHitThenExpiry(t *testing.T) {
	h := newCachedEndpointHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	const modelA, modelB = "cache-model-a", "cache-model-b"
	h.seedCatalogModel(t, modelA)
	h.seedCatalogModel(t, modelB)
	h.connectProvider(t, ctx, modelA)

	status, first := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, first)
	if ids := modelIDs(t, first); !containsID(ids, modelA) || containsID(ids, modelB) {
		t.Fatalf("initial list = %v, want only %s", ids, modelA)
	}
	if !bytes.HasSuffix(first, []byte("}\n")) {
		t.Fatalf("cached body must keep writeJSON's trailing newline: %q", first[len(first)-3:])
	}
	reads := h.st.reads()

	status, second := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, second)
	if !bytes.Equal(first, second) {
		t.Fatalf("cache hit diverged from the miss:\n%s\n%s", first, second)
	}
	if got := h.st.reads(); got != reads {
		t.Fatalf("cache hit recomputed: store reads %d -> %d", reads, got)
	}

	// Registry mutation inside the TTL: a second provider serving model B.
	h.connectProvider(t, ctx, modelB)
	status, stale := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, stale)
	if !bytes.Equal(first, stale) {
		t.Fatalf("list changed inside the TTL; expected the cached body")
	}

	h.srv.readCache.expireAllForTest()
	status, fresh := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, fresh)
	if ids := modelIDs(t, fresh); !containsID(ids, modelA) || !containsID(ids, modelB) {
		t.Fatalf("post-expiry list = %v, want both models", ids)
	}
	if got := h.st.reads(); got <= reads {
		t.Fatalf("expiry did not recompute: store reads %d -> %d", reads, got)
	}

	// include_builds is part of the key: it is computed and cached separately.
	reads = h.st.reads()
	status, builds := h.get(t, ctx, "/v1/models?include_builds=1", "test-key")
	mustOK(t, status, builds)
	if got := h.st.reads(); got <= reads {
		t.Fatal("include_builds=1 must not be served from the default key")
	}
	reads = h.st.reads()
	status, builds2 := h.get(t, ctx, "/v1/models?include_builds=1", "test-key")
	mustOK(t, status, builds2)
	if !bytes.Equal(builds, builds2) || h.st.reads() != reads {
		t.Fatal("include_builds=1 repeat should be a cache hit")
	}
}

// GET /v1/models/{id} shares the memoized entry list: repeats (found and
// not-found) do not re-read the catalog, and expiry recomputes.
func TestModelsGetCache_SharesMemoizedEntries(t *testing.T) {
	h := newCachedEndpointHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	const modelA = "cache-get-model"
	h.seedCatalogModel(t, modelA)
	h.connectProvider(t, ctx, modelA)

	status, first := h.get(t, ctx, "/v1/models/"+modelA, "test-key")
	mustOK(t, status, first)
	var entry types.ModelEntry
	if err := json.Unmarshal(first, &entry); err != nil || entry.ID != modelA {
		t.Fatalf("retrieve = %s (%v)", first, err)
	}
	reads := h.st.reads()

	status, second := h.get(t, ctx, "/v1/models/"+modelA, "test-key")
	mustOK(t, status, second)
	if !bytes.Equal(first, second) || h.st.reads() != reads {
		t.Fatalf("retrieve repeat recomputed (reads %d -> %d)", reads, h.st.reads())
	}
	if status, body := h.get(t, ctx, "/v1/models/does-not-exist", "test-key"); status != http.StatusNotFound {
		t.Fatalf("unknown id status = %d body = %s", status, body)
	}
	if h.st.reads() != reads {
		t.Fatalf("404 path re-read the catalog (reads %d -> %d)", reads, h.st.reads())
	}

	h.srv.readCache.expireAllForTest()
	status, third := h.get(t, ctx, "/v1/models/"+modelA, "test-key")
	mustOK(t, status, third)
	if h.st.reads() <= reads {
		t.Fatal("expiry did not recompute the entry list")
	}
}

// The self-route (owned-model) view is never cached: it re-reads on every
// request, and the key's allow-list is applied to the live result even while
// the public list is cache-warm.
func TestModelsList_SelfRouteViewBypassesCacheAndFiltersByKey(t *testing.T) {
	h := newCachedEndpointHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	const modelA = "owned-model-a"
	const owner = "owner-acct"
	h.seedCatalogModel(t, modelA)
	h.connectProvider(t, ctx, modelA)
	setOwnedProvider(t, h.srv, owner)

	// Warm the public cache.
	status, public := h.get(t, ctx, "/v1/models", "test-key")
	mustOK(t, status, public)
	if !containsID(modelIDs(t, public), modelA) {
		t.Fatalf("public list missing %s: %s", modelA, public)
	}

	restricted, _, err := h.mem.CreateAPIKey(owner, store.APIKeyCreate{Name: "restricted", SelfRouteOnly: true, AllowedModels: []string{"some-other-model"}})
	if err != nil {
		t.Fatal(err)
	}
	unrestricted, _, err := h.mem.CreateAPIKey(owner, store.APIKeyCreate{Name: "mine", SelfRouteOnly: true})
	if err != nil {
		t.Fatal(err)
	}

	reads := h.st.reads()
	status, body := h.get(t, ctx, "/v1/models", restricted)
	mustOK(t, status, body)
	if ids := modelIDs(t, body); len(ids) != 0 {
		t.Fatalf("allow-listed self-route key must not see %v", ids)
	}
	if h.st.reads() == reads {
		t.Fatal("self-route view must be computed live (no store read happened)")
	}

	reads = h.st.reads()
	status, body = h.get(t, ctx, "/v1/models", unrestricted)
	mustOK(t, status, body)
	var owned types.ModelListResponse
	if err := json.Unmarshal(body, &owned); err != nil {
		t.Fatal(err)
	}
	if len(owned.Data) != 1 || owned.Data[0].ID != modelA || owned.Data[0].OwnedBy != "self" {
		t.Fatalf("owned view = %+v, want one self-owned %s", owned.Data, modelA)
	}
	if h.st.reads() == reads {
		t.Fatal("second self-route view must also be computed live")
	}
	if bytes.Equal(body, public) {
		t.Fatal("self-route view must not be the cached public body")
	}
}

// GET /v1/models/openrouter: repeat within the TTL is byte-identical and
// skips the store; an admin catalog change (which runs SyncModelCatalog) is
// visible on the next request because the sync invalidates the feed entry,
// and the refreshed entry is again served from cache until it expires.
func TestOpenRouterFeedCache_RepeatHitThenExpiry(t *testing.T) {
	h := newCachedEndpointHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	const modelA, modelB = "or-model-a", "or-model-b"
	h.seedCatalogModel(t, modelA)

	status, first := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, first)
	if !strings.Contains(string(first), modelA) {
		t.Fatalf("feed missing %s: %s", modelA, first)
	}
	reads := h.st.reads()

	status, second := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, second)
	if !bytes.Equal(first, second) || h.st.reads() != reads {
		t.Fatalf("feed repeat recomputed (reads %d -> %d)", reads, h.st.reads())
	}

	h.seedCatalogModel(t, modelB) // SyncModelCatalog runs and invalidates the feed
	reads = h.st.reads()
	status, fresh := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, fresh)
	if !strings.Contains(string(fresh), modelB) {
		t.Fatalf("post-sync feed missing %s without waiting for the TTL: %s", modelB, fresh)
	}
	if h.st.reads() <= reads {
		t.Fatal("catalog sync did not recompute the feed")
	}

	// The refreshed entry is cached again until it expires.
	reads = h.st.reads()
	status, again := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, again)
	if !bytes.Equal(fresh, again) || h.st.reads() != reads {
		t.Fatalf("refreshed feed repeat recomputed (reads %d -> %d)", reads, h.st.reads())
	}
	h.srv.readCache.expireAllForTest()
	reads = h.st.reads()
	status, expired := h.get(t, ctx, "/v1/models/openrouter", "test-key")
	mustOK(t, status, expired)
	if h.st.reads() <= reads {
		t.Fatal("expiry did not recompute the feed")
	}
}

// GET /v1/providers/attestation: repeat within the TTL is byte-identical; a
// trust-level change inside the TTL is not visible until the entry expires.
func TestProviderAttestationCache_RepeatHitThenExpiry(t *testing.T) {
	h := newCachedEndpointHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	h.connectProvider(t, ctx, "attest-model")
	ids := h.reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("providers = %v", ids)
	}

	status, first := h.get(t, ctx, "/v1/providers/attestation", "")
	mustOK(t, status, first)
	if !strings.Contains(string(first), `"trust_level":"hardware"`) {
		t.Fatalf("expected hardware trust: %s", first)
	}
	status, second := h.get(t, ctx, "/v1/providers/attestation", "")
	mustOK(t, status, second)
	if !bytes.Equal(first, second) {
		t.Fatalf("repeat diverged:\n%s\n%s", first, second)
	}

	h.reg.SetTrustLevel(ids[0], registry.TrustSelfSigned)
	status, stale := h.get(t, ctx, "/v1/providers/attestation", "")
	mustOK(t, status, stale)
	if !bytes.Equal(first, stale) {
		t.Fatal("attestation changed inside the TTL; expected the cached body")
	}

	h.srv.readCache.expireAllForTest()
	status, fresh := h.get(t, ctx, "/v1/providers/attestation", "")
	mustOK(t, status, fresh)
	if !strings.Contains(string(fresh), `"trust_level":"self_signed"`) {
		t.Fatalf("post-expiry attestation still stale: %s", fresh)
	}
}

// encodeCachedJSON renders exactly what writeJSON writes, so hits and misses
// are byte-identical.
func TestEncodeCachedJSONMatchesWriteJSON(t *testing.T) {
	v := map[string]any{"b": []int{1, 2}, "a": "x<y&z", "n": nil}
	rec := httptest.NewRecorder()
	writeJSON(rec, http.StatusOK, v)
	body, err := encodeCachedJSON(v)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(rec.Body.Bytes(), body) {
		t.Fatalf("encodeCachedJSON = %q, writeJSON = %q", body, rec.Body.Bytes())
	}
}

// Typed values share the map with byte entries: independent keys, TTL
// expiry, and Get/GetValue never return the other kind.
func TestTTLCacheTypedValues(t *testing.T) {
	c := newTTLCache()
	c.SetValue("entries", []string{"a"}, time.Minute)
	c.Set("body", []byte("{}"), time.Minute)
	if v, ok := c.GetValue("entries"); !ok || len(v.([]string)) != 1 {
		t.Fatalf("GetValue = %v, %v", v, ok)
	}
	if _, ok := c.Get("entries"); ok {
		t.Fatal("Get must not return a typed entry as bytes")
	}
	if _, ok := c.GetValue("body"); ok {
		t.Fatal("GetValue must not return a byte entry as a value")
	}
	c.SetValue("stale", 1, -time.Second)
	if _, ok := c.GetValue("stale"); ok {
		t.Fatal("expired typed value returned")
	}
	c.PurgeExpired()
	if c.Len() != 2 {
		t.Fatalf("Len after purge = %d, want 2", c.Len())
	}
}
