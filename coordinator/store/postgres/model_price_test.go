package postgres

import (
	"context"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

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
		store.HashKey(consumer), legacyReq); err != nil {
		t.Fatalf("insert legacy row: %v", err)
	}
	if err := s.migrate(ctx); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	s.RecordUsage(store.UsageRecord{ProviderID: "p", ConsumerKey: consumer, Model: "m", RequestID: uniqueID("new-usage"), PromptTokens: 100, CachedTokens: 60, CompletionTokens: 10, CostMicroUSD: 5})

	byReq := map[string]store.UsageRecord{}
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
