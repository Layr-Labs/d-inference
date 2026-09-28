package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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

// settleOnce registers a provider for model, reserves `reserve` for the test
// consumer and settles one completion carrying usage. Returns the consumer's
// balance before the reservation.
func settleOnce(t *testing.T, srv *Server, ledger *payments.Ledger, providerID, model, consumerID string, reserve int64, usage protocol.UsageInfo) (initial int64) {
	t.Helper()
	provider := srv.registry.Register(providerID, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	initial = ledger.Balance(consumerID)
	if err := ledger.Charge(consumerID, reserve, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}
	pr := &registry.PendingRequest{
		RequestID:        "req-" + providerID,
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserve,
		ChunkCh:          make(chan registry.ProviderChunk, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})
	return initial
}

// A valid cache hit bills the cached prefix at the platform row's explicit
// cache_read_price and the rest of the prompt at the input price; the
// difference to the worst-case reservation is refunded and the usage history
// records the cached count so the bill can be reconciled.
func TestSettlementBillsCachedTokensAtCacheReadRate(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-priced-model"
	cacheRead := int64(30_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &cacheRead}); err != nil {
		t.Fatal(err)
	}

	usage := cacheHitUsage()
	// 2,000 uncached × $0.30/1M + 8,000 cached × $0.03/1M + 500 × $1.20/1M.
	const want int64 = 600 + 240 + 600
	if got := (payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: cacheRead}).CostWithMinimum(billableUsage(usage)); got != want {
		t.Fatalf("test arithmetic: cost = %d, want %d", got, want)
	}
	cold := payments.Rates{Input: 300_000, Output: 1_200_000}.CostWithMinimum(payments.Usage{PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens})
	if cold <= want {
		t.Fatalf("test setup: cold cost %d must exceed cached cost %d", cold, want)
	}

	initial := settleOnce(t, srv, ledger, "cache-prov", model, testConsumerID, cold, usage)

	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d (debit %d, refund of %d from the reservation)", got, initial-want, want, cold-want)
	}
	entries := ledger.Usage(testConsumerID)
	if len(entries) != 1 {
		t.Fatalf("usage entries = %d, want 1", len(entries))
	}
	if entries[0].CachedTokens != usage.CachedTokens || entries[0].PromptTokens != usage.PromptTokens || entries[0].CostMicroUSD != want {
		t.Fatalf("usage entry = %+v, want cached=%d prompt=%d cost=%d", entries[0], usage.CachedTokens, usage.PromptTokens, want)
	}
	rows := awaitUsageRows(t, st, testConsumerID)
	if len(rows) != 1 || rows[0].CachedTokens != usage.CachedTokens || rows[0].CostMicroUSD != want {
		t.Fatalf("persisted usage = %+v, want one row with cached=%d cost=%d", rows, usage.CachedTokens, want)
	}
}

// awaitUsageRows waits for the settlement's asynchronous usage insert
// (saferun.Go in handleCompleteAt) and returns the consumer's rows.
func awaitUsageRows(t *testing.T, st *store.MemoryStore, consumerID string) []store.UsageRecord {
	t.Helper()
	if !waitForCond(5*time.Second, func() bool { return len(st.UsageByConsumer(consumerID)) > 0 }) {
		t.Fatal("usage row was not persisted")
	}
	return st.UsageByConsumer(consumerID)
}

// A platform row without an explicit cache_read_price bills cached tokens at
// the derived default discount off its own input price.
func TestSettlementDerivesCacheReadDiscountWhenUnset(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-derived-model"
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000}); err != nil {
		t.Fatal(err)
	}
	usage := cacheHitUsage()
	want := payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: payments.DefaultCacheReadPrice(300_000)}.CostWithMinimum(billableUsage(usage))
	// 2,000 × 0.30 + 8,000 × 0.15 + 500 × 1.20 per 1M.
	if want != 600+1_200+600 {
		t.Fatalf("test arithmetic: want = %d", want)
	}

	initial := settleOnce(t, srv, ledger, "derived-prov", model, testConsumerID, 10_000, usage)
	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d", got, initial-want)
	}
}

// An explicit cache_read_price of 0 makes cached prompt tokens free; the rest
// of the request still bills.
func TestSettlementFreeCacheReadPrice(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-free-model"
	zero := int64(0)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &zero}); err != nil {
		t.Fatal(err)
	}
	usage := cacheHitUsage()
	const want int64 = 600 + 0 + 600
	initial := settleOnce(t, srv, ledger, "free-prov", model, testConsumerID, 10_000, usage)
	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d", got, initial-want)
	}
}

// A malformed cache report (cached > prompt) is rejected by validCacheUsage and
// must bill every prompt token at the full input price — the provider's cache
// claim cannot lower the bill unless it is well-formed.
func TestSettlementIgnoresInvalidCacheUsage(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-invalid-model"
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000}); err != nil {
		t.Fatal(err)
	}
	usage := cacheHitUsage()
	usage.CachedTokens = usage.PromptTokens + 1
	usage.PrefillTokensSaved = usage.CachedTokens
	want := payments.Rates{Input: 300_000, Output: 1_200_000}.CostWithMinimum(payments.Usage{PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens})

	initial := settleOnce(t, srv, ledger, "invalid-prov", model, testConsumerID, 10_000, usage)
	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d (full input price, no cache discount)", got, initial-want)
	}
	if entries := ledger.Usage(testConsumerID); len(entries) != 1 || entries[0].CachedTokens != 0 {
		t.Fatalf("usage entries = %+v, want one entry with cached_tokens 0", entries)
	}
}

// A provider's own price row carries its own cache-read rate for direct
// consumers (price resolution order: provider custom → platform).
func TestSettlementUsesProviderCustomCacheReadPrice(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-provider-price-model"
	const account = "cache-provider-account"
	platformCache := int64(10_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &platformCache}); err != nil {
		t.Fatal(err)
	}
	providerCache := int64(100_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: account, Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &providerCache}); err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("custom-cache-prov", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = account
	provider.Mu().Unlock()

	usage := cacheHitUsage()
	want := payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: providerCache}.CostWithMinimum(billableUsage(usage))
	initial := ledger.Balance(testConsumerID)
	const reserve int64 = 10_000
	if err := ledger.Charge(testConsumerID, reserve, "reserve:"+testConsumerID); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{
		RequestID: "custom-cache-req", Model: model, ConsumerKey: testConsumerID, ReservedMicroUSD: reserve,
		ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage})

	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d (provider cache-read rate %d, not platform %d)", got, initial-want, providerCache, platformCache)
	}
	if got := st.GetWithdrawableBalance(account); got != payments.ProviderPayout(want) {
		t.Fatalf("provider payout = %d, want %d", got, payments.ProviderPayout(want))
	}
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
	srv.handleListModelsOpenRouter(rec, httptest.NewRequest(http.MethodGet, "/v1/models/openrouter", nil))
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

	initial := settleOnce(t, srv, ledger, "or-cache-prov", model, testConsumerID, 100_000, usage)
	if got := ledger.Balance(testConsumerID); got != initial-wantMicro {
		t.Fatalf("service debit = %d, want %d (the feed's per-token math)", initial-got, wantMicro)
	}
}

// registerActiveTextModel puts a minimal active registry entry in the catalog
// so the OpenRouter feed lists model.
func registerActiveTextModel(t *testing.T, srv *Server, st *store.MemoryStore, model string) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: model, DisplayName: model, Quantization: "4bit",
		MaxContextLength: 8192, MaxOutputLength: 2048, MinRAMGB: 8, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	version := &store.ModelVersion{ModelID: model, Version: "v1", R2Prefix: modelR2Prefix(model, "v1"), AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready"}
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
	srv, st := testServerWithConfig(t, ServerConfig{AdminKey: "admin-secret"})
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
	srv, st := testServer(t)
	user := &store.User{AccountID: "prov-acct", PrivyUserID: "did:privy:prov"}
	if err := st.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	put := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPut, "/v1/pricing", bytes.NewBufferString(body))
		rec := httptest.NewRecorder()
		srv.handleSetPricing(rec, withPrivyUser(req, user))
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
	settleOnce(t, srv, ledger, "usage-prov", model, testConsumerID, 10_000, usage)

	fetch := func() []payments.UsageEntry {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
		req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, testConsumerID))
		rec := httptest.NewRecorder()
		srv.handleUsage(rec, req)
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
	srv.ledger = payments.NewLedger(st)
	persisted := fetch()
	if len(persisted) != 1 || persisted[0].CachedTokens != usage.CachedTokens {
		t.Fatalf("persisted usage = %+v, want cached_tokens %d", persisted, usage.CachedTokens)
	}
}
