package postgres_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProviderAndReputationPublicationIsAtomic(t *testing.T) {
	ctx := context.Background()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := s.pool.Exec(ctx, `ALTER TABLE provider_reputation ADD CONSTRAINT valid_restore_jobs CHECK(total_jobs >= 0)`); err != nil {
		t.Fatal(err)
	}
	rec := store.ProviderRecord{ID: "completed", SerialNumber: "serial", Hardware: json.RawMessage(`{}`), Models: json.RawMessage(`[]`), RegisteredAt: time.Now(), LastSeen: time.Now(), LifetimeTokensGenerated: 700}
	if err := s.UpsertProviderWithReputation(ctx, rec, store.ReputationRecord{TotalJobs: -1}); err == nil {
		t.Fatal("expected reputation failure")
	}
	if got, err := s.GetProviderForRestore(ctx, "serial", "", nil); err != nil || got != nil {
		t.Fatalf("identity escaped failed reputation transaction: %+v %v", got, err)
	}
	cached := store.NewCached(s, store.DefaultCacheConfig())
	if err := cached.UpsertProviderWithReputation(ctx, rec, store.ReputationRecord{TotalJobs: 12}); err != nil {
		t.Fatal(err)
	}
	got, err := cached.GetProviderForRestore(ctx, "serial", "", nil)
	if err != nil || got == nil || got.LifetimeTokensGenerated != 700 {
		t.Fatalf("missing completed record: %+v %v", got, err)
	}
	rep, err := cached.GetReputation(ctx, got.ID)
	if err != nil || rep.TotalJobs != 12 {
		t.Fatalf("missing completed reputation: %+v %v", rep, err)
	}
}
