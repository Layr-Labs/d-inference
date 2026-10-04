package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// The cache-read rate round-trips through both backends: unset stays unset
// (nil, so billing derives it), an explicit value — including 0 — comes back
// verbatim, and an update can clear it again.
func TestModelPriceCacheReadRoundTrip(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			model := uniqueID("cache-priced")
			if err := s.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000}); err != nil {
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
				if err := s.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &explicit}); err != nil {
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
			if err := s.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 310_000, OutputPrice: 1_200_000}); err != nil {
				t.Fatalf("clear: %v", err)
			}
			got, ok = s.GetModelPrice("platform", model)
			if !ok || got.InputPrice != 310_000 || got.CacheReadPrice != nil {
				t.Fatalf("cleared row = %+v ok=%v, want input 310000 cache nil", got, ok)
			}

			listed := s.ListModelPrices("platform")
			var found *store.ModelPrice
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
	if err := s.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 100_000, OutputPrice: 400_000, CacheReadPrice: &explicit}); err != nil {
		t.Fatal(err)
	}
	// Populate the in-memory cache, then read through it.
	for i := 0; i < 2; i++ {
		got, ok := s.GetModelPrice("platform", model)
		if !ok || got.CacheReadPrice == nil || *got.CacheReadPrice != 20_000 {
			t.Fatalf("read %d = %+v ok=%v", i, got, ok)
		}
	}
	if err := s.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 100_000, OutputPrice: 400_000}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.GetModelPrice("platform", model); got.CacheReadPrice != nil {
		t.Fatalf("stale cached cache-read rate served after upsert: %+v", got)
	}
}

// Usage rows persist the cached-token count and every reader returns it.
func TestUsageRecordCachedTokens(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer := uniqueID("consumer")
			s.RecordUsage(store.UsageRecord{
				ProviderID: "provider-1", ConsumerKey: consumer, KeyID: "key-1", Model: "build-v1", PublicModel: "alias",
				RequestID: uniqueID("req"), PromptTokens: 10_000, CachedTokens: 8_000, CompletionTokens: 500, CostMicroUSD: 1_440,
			})
			byConsumer := s.UsageByConsumer(consumer)
			if len(byConsumer) != 1 || byConsumer[0].CachedTokens != 8_000 || byConsumer[0].PromptTokens != 10_000 || byConsumer[0].CostMicroUSD != 1_440 {
				t.Fatalf("UsageByConsumer = %+v, want one row with cached 8000", byConsumer)
			}
			var all *store.UsageRecord
			for _, r := range s.UsageRecords() {
				if r.RequestID == byConsumer[0].RequestID {
					r := r
					all = &r
				}
			}
			if all == nil || all.CachedTokens != 8_000 {
				t.Fatalf("UsageRecords row = %+v, want cached 8000", all)
			}
		})
	}
}
