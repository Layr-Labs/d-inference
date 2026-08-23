package store

import (
	"context"
	"testing"
	"time"
)

func TestPostgresSeedKey(t *testing.T) {
	s := testPostgresStore(t)

	if err := s.SeedKey("my-admin-key"); err != nil {
		t.Fatalf("SeedKey: %v", err)
	}
	if !s.ValidateKey("my-admin-key") {
		t.Error("seeded key should be valid")
	}
	if err := s.SeedKey("my-admin-key"); err != nil {
		t.Fatalf("SeedKey duplicate: %v", err)
	}
	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestPostgresProviderRecordStatsPersisted(t *testing.T) {
	s := testPostgresStore(t)
	rec := ProviderRecord{
		ID: "provider-1", Hardware: []byte(`{"chip":"M4 Max"}`), Models: []byte(`["model-a"]`),
		Backend: "vllm_mlx", TrustLevel: "hardware", Attested: true,
		SEPublicKey: "se-key", SerialNumber: "serial-1",
		LifetimeRequestsServed: 42, LifetimeTokensGenerated: 1234,
		LastSessionRequestsServed: 7, LastSessionTokensGenerated: 222,
		RegisteredAt: time.Now(), LastSeen: time.Now(),
	}
	if err := s.UpsertProvider(context.Background(), rec); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}
	got, err := s.GetProviderRecord(context.Background(), rec.ID)
	if err != nil {
		t.Fatalf("GetProviderRecord: %v", err)
	}
	if got.LifetimeRequestsServed != rec.LifetimeRequestsServed ||
		got.LifetimeTokensGenerated != rec.LifetimeTokensGenerated ||
		got.LastSessionRequestsServed != rec.LastSessionRequestsServed ||
		got.LastSessionTokensGenerated != rec.LastSessionTokensGenerated {
		t.Fatalf("provider stats mismatch: got %+v want %+v", got, rec)
	}
}
