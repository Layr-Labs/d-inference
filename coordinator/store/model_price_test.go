package store

import (
	"context"
	"testing"
	"time"
)

// The cache-read rate round-trips through both backends: unset stays unset
// (nil, so billing derives it), an explicit value — including 0 — comes back
// verbatim, and an update can clear it again.
func TestModelPriceCacheReadRoundTrip(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			model := uniqueID("cache-priced")
			if err := s.SetModelPrice(ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000}); err != nil {
				t.Fatalf("set unset: %v", err)
			}
			got, ok := s.GetModelPrice("platform", model)
			if !ok || got.InputPrice != 300_000 || got.OutputPrice != 1_200_000 || got.CacheReadPrice != nil {
				t.Fatalf("unset row = %+v ok=%v, want input 300000 output 1200000 cache nil", got, ok)
			}
			if got.AccountID != "platform" || got.Model != model {
				t.Fatalf("row identity = (%q, %q)", got.AccountID, got.Model)
			}

			for _, explicit := range []int64{0, 45_000} {
				explicit := explicit
				if err := s.SetModelPrice(ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &explicit}); err != nil {
					t.Fatalf("set explicit %d: %v", explicit, err)
				}
				got, ok = s.GetModelPrice("platform", model)
				if !ok || got.CacheReadPrice == nil || *got.CacheReadPrice != explicit {
					t.Fatalf("explicit %d row = %+v ok=%v", explicit, got, ok)
				}
				// The returned pointer must not alias stored state.
				*got.CacheReadPrice = 999
				if again, _ := s.GetModelPrice("platform", model); *again.CacheReadPrice != explicit {
					t.Fatalf("mutating the returned row changed the stored price: %d", *again.CacheReadPrice)
				}
			}

			// Clearing: an upsert without a cache-read rate resets it to unset.
			if err := s.SetModelPrice(ModelPrice{AccountID: "platform", Model: model, InputPrice: 310_000, OutputPrice: 1_200_000}); err != nil {
				t.Fatalf("clear: %v", err)
			}
			got, ok = s.GetModelPrice("platform", model)
			if !ok || got.InputPrice != 310_000 || got.CacheReadPrice != nil {
				t.Fatalf("cleared row = %+v ok=%v, want input 310000 cache nil", got, ok)
			}

			listed := s.ListModelPrices("platform")
			var found *ModelPrice
			for i := range listed {
				if listed[i].Model == model {
					found = &listed[i]
				}
			}
			if found == nil || found.CacheReadPrice != nil || found.InputPrice != 310_000 {
				t.Fatalf("listed row = %+v, want the cleared row", found)
			}

			if _, ok := s.GetModelPrice("platform", uniqueID("absent")); ok {
				t.Fatal("absent row reported ok")
			}
		})
	}
}

// The Postgres price cache must serve the cache-read rate it cached, and an
// upsert must invalidate it so a changed rate is visible immediately.
func TestPostgresModelPriceCacheTracksCacheRead(t *testing.T) {
	s := testPostgresStore(t)
	model := uniqueID("cached-price")
	explicit := int64(20_000)
	if err := s.SetModelPrice(ModelPrice{AccountID: "platform", Model: model, InputPrice: 100_000, OutputPrice: 400_000, CacheReadPrice: &explicit}); err != nil {
		t.Fatal(err)
	}
	// Populate the in-memory cache, then read through it.
	for i := 0; i < 2; i++ {
		got, ok := s.GetModelPrice("platform", model)
		if !ok || got.CacheReadPrice == nil || *got.CacheReadPrice != 20_000 {
			t.Fatalf("read %d = %+v ok=%v", i, got, ok)
		}
	}
	if err := s.SetModelPrice(ModelPrice{AccountID: "platform", Model: model, InputPrice: 100_000, OutputPrice: 400_000}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetModelPrice("platform", model); got.CacheReadPrice != nil {
		t.Fatalf("stale cached cache-read rate served after upsert: %+v", got)
	}
}

// A model_prices table created before cache_read_price existed gains the
// column on the next migrate() with existing rows reading back as unset.
func TestPostgresModelPricesMigrationAddsCacheReadColumn(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, "ALTER TABLE model_prices DROP COLUMN IF EXISTS cache_read_price"); err != nil {
		t.Fatalf("drop column: %v", err)
	}
	model := uniqueID("legacy-row")
	if _, err := s.pool.Exec(ctx,
		"INSERT INTO model_prices (account_id, model, input_price, output_price) VALUES ('platform', $1, 50000, 200000)", model); err != nil {
		t.Fatalf("insert legacy row: %v", err)
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	got, ok := s.GetModelPrice("platform", model)
	if !ok || got.InputPrice != 50_000 || got.OutputPrice != 200_000 || got.CacheReadPrice != nil {
		t.Fatalf("legacy row after migration = %+v ok=%v, want cache_read_price unset", got, ok)
	}
	if _, err := s.pool.Exec(ctx, "DELETE FROM model_prices WHERE model = $1", model); err != nil {
		t.Fatalf("cleanup: %v", err)
	}
}

// A usage table created before cached_tokens existed gains the column on the
// next migrate(); rows written before it read back as 0 cached tokens (they
// were billed at the full input price) and new rows persist their count.
func TestPostgresUsageMigrationAddsCachedTokensColumn(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, "ALTER TABLE usage DROP COLUMN IF EXISTS cached_tokens"); err != nil {
		t.Fatalf("drop column: %v", err)
	}
	legacyReq := uniqueID("legacy-usage")
	consumer := uniqueID("legacy-consumer")
	if _, err := s.pool.Exec(ctx,
		"INSERT INTO usage (provider_id, consumer_key_hash, model, prompt_tokens, completion_tokens, request_id, cost_micro_usd) VALUES ('p', $1, 'm', 100, 10, $2, 7)",
		hashKey(consumer), legacyReq); err != nil {
		t.Fatalf("insert legacy row: %v", err)
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	s.RecordUsage(UsageRecord{ProviderID: "p", ConsumerKey: consumer, Model: "m", RequestID: uniqueID("new-usage"), PromptTokens: 100, CachedTokens: 60, CompletionTokens: 10, CostMicroUSD: 5})

	byReq := map[string]UsageRecord{}
	for _, r := range s.UsageByConsumer(consumer) {
		byReq[r.RequestID] = r
	}
	if got, ok := byReq[legacyReq]; !ok || got.CachedTokens != 0 || got.PromptTokens != 100 {
		t.Fatalf("legacy row = %+v ok=%v, want cached_tokens 0", got, ok)
	}
	if len(byReq) != 2 {
		t.Fatalf("rows for consumer = %d, want 2 (legacy + new)", len(byReq))
	}
	for id, r := range byReq {
		if id != legacyReq && r.CachedTokens != 60 {
			t.Fatalf("new row = %+v, want cached_tokens 60", r)
		}
	}
}

// Usage rows persist the cached-token count and every reader returns it.
func TestUsageRecordCachedTokens(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer := uniqueID("consumer")
			s.RecordUsage(UsageRecord{
				ProviderID: "provider-1", ConsumerKey: consumer, KeyID: "key-1", Model: "build-v1", PublicModel: "alias",
				RequestID: uniqueID("req"), PromptTokens: 10_000, CachedTokens: 8_000, CompletionTokens: 500, CostMicroUSD: 1_440,
			})
			byConsumer := s.UsageByConsumer(consumer)
			if len(byConsumer) != 1 || byConsumer[0].CachedTokens != 8_000 || byConsumer[0].PromptTokens != 10_000 || byConsumer[0].CostMicroUSD != 1_440 {
				t.Fatalf("UsageByConsumer = %+v, want one row with cached 8000", byConsumer)
			}
			var all *UsageRecord
			for _, r := range s.UsageRecords() {
				if r.RequestID == byConsumer[0].RequestID {
					r := r
					all = &r
				}
			}
			if all == nil || all.CachedTokens != 8_000 {
				t.Fatalf("UsageRecords row = %+v, want cached 8000", all)
			}
			since := s.UsageRecordsSince(time.Now().Add(-time.Hour))
			var recent *UsageRecord
			for _, r := range since {
				if r.RequestID == byConsumer[0].RequestID {
					r := r
					recent = &r
				}
			}
			if recent == nil || recent.CachedTokens != 8_000 {
				t.Fatalf("UsageRecordsSince row = %+v, want cached 8000", recent)
			}
		})
	}
}
