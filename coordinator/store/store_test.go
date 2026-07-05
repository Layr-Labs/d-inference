package store

import (
	"testing"
)

func TestNewWithAdminKey(t *testing.T) {
	s := NewMemory(Config{AdminKey: "test-admin-key"})
	if !s.ValidateKey("test-admin-key") {
		t.Error("admin key should be valid")
	}
	if s.KeyCount() != 1 {
		t.Errorf("key count = %d, want 1", s.KeyCount())
	}
}

func TestNewWithoutAdminKey(t *testing.T) {
	s := NewMemory(Config{})
	if s.KeyCount() != 0 {
		t.Errorf("key count = %d, want 0", s.KeyCount())
	}
}

func TestRecordUsageFullWithPublicModel(t *testing.T) {
	s := NewMemory(Config{})

	s.RecordUsageFullWithPublicModel("provider-1", "consumer-key", "key-1", "build-v1", "public-alias", "req-1", 50, 100, 123, nil)

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
	s := NewMemory(Config{})
	s.RecordUsage("p1", "k1", "m1", 10, 20)

	records := s.UsageRecords()
	records[0].PromptTokens = 999

	// Original should be unchanged.
	original := s.UsageRecords()
	if original[0].PromptTokens != 10 {
		t.Error("UsageRecords should return a copy")
	}
}
