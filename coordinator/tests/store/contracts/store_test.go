package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestNewWithAdminKey(t *testing.T) {
	s := memory.NewMemory(store.Config{AdminKey: "test-admin-key"})
	if !keyAuthenticates(s, "test-admin-key") {
		t.Error("admin key should be valid")
	}
	if n := activeKeyCount(t, s, ""); n != 1 {
		t.Errorf("key count = %d, want 1", n)
	}
}

func TestNewWithoutAdminKey(t *testing.T) {
	s := memory.NewMemory(store.Config{})
	if n := activeKeyCount(t, s, ""); n != 0 {
		t.Errorf("key count = %d, want 0", n)
	}
}

func TestRecordUsagePublicModel(t *testing.T) {
	s := memory.NewMemory(store.Config{})

	s.RecordUsage(store.UsageRecord{ProviderID: "provider-1", ConsumerKey: "consumer-key", KeyID: "key-1", Model: "build-v1", PublicModel: "public-alias", RequestID: "req-1", PromptTokens: 50, CompletionTokens: 100, CostMicroUSD: 123})

	records := s.UsageRecords()
	if len(records) != 1 {
		t.Fatalf("usage records = %d, want 1", len(records))
	}
	if records[0].Model != "build-v1" {
		t.Fatalf("model = %q, want concrete build", records[0].Model)
	}
	if records[0].PublicModel != "public-alias" {
		t.Fatalf("public_model = %q, want public alias", records[0].PublicModel)
	}
}

func TestUsageRecordsReturnsCopy(t *testing.T) {
	s := memory.NewMemory(store.Config{})
	s.RecordUsage(store.UsageRecord{ProviderID: "p1", ConsumerKey: "k1", Model: "m1", PromptTokens: 10, CompletionTokens: 20})

	records := s.UsageRecords()
	records[0].PromptTokens = 999

	// Original should be unchanged.
	original := s.UsageRecords()
	if original[0].PromptTokens != 10 {
		t.Error("UsageRecords should return a copy")
	}
}
