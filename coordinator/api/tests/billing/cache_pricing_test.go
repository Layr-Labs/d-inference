package billing_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// cacheHitUsage is a valid provider cache report: 8,000 of 10,000 prompt tokens
// served from the SSD prefix cache.
func cacheHitUsage() protocol.UsageInfo {
	return protocol.UsageInfo{
		PromptTokens:       10_000,
		CompletionTokens:   500,
		CacheOutcome:       "hit",
		CacheTier:          "ssd",
		CachedTokens:       8_000,
		PrefillTokensSaved: 7_900,
		CacheStageMs:       12.5,
	}
}

// awaitUsageRows waits for the settlement's asynchronous usage insert
// (saferun.Go in handleCompleteAt) and returns the consumer's rows.
func awaitUsageRows(t *testing.T, st *memory.MemoryStore, consumerID string) []store.UsageRecord {
	t.Helper()
	if !waitForCond(5*time.Second, func() bool { return len(st.UsageByConsumer(consumerID)) > 0 }) {
		t.Fatal("usage row was not persisted")
	}
	return st.UsageByConsumer(consumerID)
}

// OpenRouter bills its users from the usage it receives and the per-token
// prices in the provider feed. A service-account debit for a cache hit must
// equal exactly what the feed's prompt / input_cache_read / completion strings
// imply, or Darkbloom over- or under-charges OpenRouter relative to its own
// advertised price.
func TestServiceSettlementMatchesOpenRouterFeedCachePricing(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "mlx-community/cache-feed-model"
	if err := st.CreateUser(&store.User{AccountID: testConsumerID, PrivyUserID: "did:privy:or-cache", Role: store.RoleService}); err != nil {
		t.Fatal(err)
	}
	// Explicit cache-read rate on the platform row; feed and settlement must
	// both read it.
	cacheRead := int64(45_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &cacheRead}); err != nil {
		t.Fatal(err)
	}
	registerActiveTextModel(t, srv, st, model)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("feed status = %d body = %s", rec.Code, rec.Body.String())
	}
	var feed types.OpenRouterModelsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &feed); err != nil {
		t.Fatal(err)
	}
	var pricing *types.ModelPricing
	for i := range feed.Data {
		if feed.Data[i].ID == model {
			pricing = &feed.Data[i].Pricing
		}
	}
	if pricing == nil {
		t.Fatalf("model missing from feed: %s", rec.Body.String())
	}
	if pricing.InputCacheRead != "0.000000045" {
		t.Fatalf("feed input_cache_read = %q, want 0.000000045", pricing.InputCacheRead)
	}

	usage := cacheHitUsage()
	perToken := func(s string) float64 {
		v, err := strconv.ParseFloat(s, 64)
		if err != nil {
			t.Fatalf("parse feed price %q: %v", s, err)
		}
		return v
	}
	advertisedUSD := float64(usage.PromptTokens-usage.CachedTokens)*perToken(pricing.Prompt) +
		float64(usage.CachedTokens)*perToken(pricing.InputCacheRead) +
		float64(usage.CompletionTokens)*perToken(pricing.Completion)
	wantMicro := int64(advertisedUSD*1_000_000 + 0.5)
	// 2,000 × 0.30 + 8,000 × 0.045 + 500 × 1.20 per 1M = 600 + 360 + 600.
	if wantMicro != 1_560 {
		t.Fatalf("test arithmetic: advertised cost = %d µUSD", wantMicro)
	}

	initial := settleOnce(t, srv, ledger, model, testConsumerID, usage)
	if got := ledger.Balance(testConsumerID); got != initial-wantMicro {
		t.Fatalf("service debit = %d, want %d (the feed's per-token math)", initial-got, wantMicro)
	}
}

// registerActiveTextModel puts a minimal active registry entry in the catalog
// so the OpenRouter feed lists model.
func registerActiveTextModel(t *testing.T, srv *billingFixture, st *memory.MemoryStore, model string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: model, DisplayName: model, Quantization: "4bit",
		MaxContextLength: 16384, MaxOutputLength: 8192, MinRAMGB: 8, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testkit.ModelHash, Role: "config"}}
	version := &store.ModelVersion{ModelID: model, Version: "v1", R2Prefix: testkit.ModelPrefix(model, "v1"), AggregateSHA256: testkit.ModelHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}
	if err := st.SetModelVersion(entry, version, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(model, "v1"); err != nil {
		t.Fatal(err)
	}
	srv.SyncModelCatalog()
}

// PUT /v1/admin/pricing accepts an optional cache_read_price, rejects one
// outside [0, input_price], and GET /v1/pricing publishes the effective rate —
// derived when the row sets none — plus the fallback.
func TestAdminPricingCacheReadRoundTrip(t *testing.T) {
	srv, st := pricingTestServer(t, api.ServerConfig{AdminKey: "admin-secret"})
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	put := func(body string) (int, map[string]any) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPut, ts.URL+"/v1/admin/pricing", bytes.NewBufferString(body))
		req.Header.Set("Authorization", "Bearer admin-secret")
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}

	// Omitted cache_read_price → stored unset, reported as the derived default.
	code, out := put(`{"model":"m-derived","input_price":300000,"output_price":1200000}`)
	if code != http.StatusOK {
		t.Fatalf("derived put status = %d body = %v", code, out)
	}
	if out["cache_read_price"] != float64(150_000) || out["cache_read_usd"] != "$0.1500" {
		t.Fatalf("derived response = %v, want cache_read_price 150000 / $0.1500", out)
	}
	if mp, ok := st.GetModelPrice("platform", "m-derived"); !ok || mp.CacheReadPrice != nil {
		t.Fatalf("stored derived row = %+v ok=%v, want CacheReadPrice nil", mp, ok)
	}

	// Explicit rate is stored verbatim; zero is allowed (free cached tokens).
	code, out = put(`{"model":"m-explicit","input_price":300000,"output_price":1200000,"cache_read_price":0}`)
	if code != http.StatusOK || out["cache_read_price"] != float64(0) {
		t.Fatalf("explicit zero put = %d %v", code, out)
	}
	if mp, ok := st.GetModelPrice("platform", "m-explicit"); !ok || mp.CacheReadPrice == nil || *mp.CacheReadPrice != 0 {
		t.Fatalf("stored explicit row = %+v ok=%v, want CacheReadPrice 0", mp, ok)
	}

	// Out of range: above input, or negative.
	if code, out = put(`{"model":"m-bad","input_price":300000,"output_price":1200000,"cache_read_price":300001}`); code != http.StatusBadRequest {
		t.Fatalf("cache_read_price > input_price accepted: %d %v", code, out)
	}
	if code, out = put(`{"model":"m-bad","input_price":300000,"output_price":1200000,"cache_read_price":-1}`); code != http.StatusBadRequest {
		t.Fatalf("negative cache_read_price accepted: %d %v", code, out)
	}
	if _, ok := st.GetModelPrice("platform", "m-bad"); ok {
		t.Fatal("rejected price must not be stored")
	}

	// Public read publishes the effective rates.
	resp, err := http.Get(ts.URL + "/v1/pricing")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var pricing types.PricingResponse
	if err := json.NewDecoder(resp.Body).Decode(&pricing); err != nil {
		t.Fatal(err)
	}
	if pricing.FallbackCacheReadPrice != payments.DefaultCacheReadPrice(payments.DefaultInputPricePerMillion) || pricing.FallbackCacheReadUSD != "$0.0250" {
		t.Fatalf("fallback cache read = %d / %q", pricing.FallbackCacheReadPrice, pricing.FallbackCacheReadUSD)
	}
	got := map[string]int64{}
	for _, p := range pricing.Prices {
		got[p.Model] = p.CacheReadPrice
	}
	if got["m-derived"] != 150_000 || got["m-explicit"] != 0 || len(pricing.Prices) != 2 {
		t.Fatalf("published cache read prices = %v (rows %d), want m-derived=150000 m-explicit=0", got, len(pricing.Prices))
	}
}

// A provider setting its own price through PUT /v1/pricing can set a
// cache-read rate, subject to the same bound.
func TestProviderSetPricingCacheRead(t *testing.T) {
	srv, st := pricingTestServer(t, api.ServerConfig{})
	user := &store.User{AccountID: "prov-acct", PrivyUserID: "did:privy:prov"}
	if err := st.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	put := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "/v1/pricing", bytes.NewBufferString(body))
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, srv.withUser(req, user))
		return rec
	}
	if rec := put(`{"model":"m","input_price":100000,"output_price":400000,"cache_read_price":20000}`); rec.Code != http.StatusOK {
		t.Fatalf("set pricing = %d %s", rec.Code, rec.Body.String())
	}
	mp, ok := st.GetModelPrice("prov-acct", "m")
	if !ok || mp.CacheReadPrice == nil || *mp.CacheReadPrice != 20_000 {
		t.Fatalf("stored provider price = %+v ok=%v", mp, ok)
	}
	if rec := put(`{"model":"m","input_price":100000,"output_price":400000,"cache_read_price":100001}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("over-input cache_read_price accepted: %d %s", rec.Code, rec.Body.String())
	}
	if mp, _ := st.GetModelPrice("prov-acct", "m"); *mp.CacheReadPrice != 20_000 {
		t.Fatalf("rejected update overwrote the stored price: %+v", mp)
	}
}

// GET /v1/payments/usage carries cached_tokens both from the in-process
// history and from the persisted usage rows after a restart.
func TestUsageHistoryReportsCachedTokens(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-usage-model"
	usage := cacheHitUsage()
	settleOnce(t, srv, ledger, model, testConsumerID, usage)

	fetch := func() []payments.UsageEntry {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
		req.Header.Set("Authorization", "Bearer test-key")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("usage status = %d body = %s", rec.Code, rec.Body.String())
		}
		var resp types.UsageResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		return resp.Usage
	}
	inMemory := fetch()
	if len(inMemory) != 1 || inMemory[0].CachedTokens != usage.CachedTokens {
		t.Fatalf("in-memory usage = %+v, want cached_tokens %d", inMemory, usage.CachedTokens)
	}

	// Simulate a restart: the in-memory history is gone and the handler falls
	// back to the persisted rows (written asynchronously by the settlement).
	awaitUsageRows(t, st, testConsumerID)
	srv = newBillingFixture(t, registry.New(srv.logger), st, api.ServerConfig{}, srv.logger)
	persisted := fetch()
	if len(persisted) != 1 || persisted[0].CachedTokens != usage.CachedTokens {
		t.Fatalf("persisted usage = %+v, want cached_tokens %d", persisted, usage.CachedTokens)
	}
}
