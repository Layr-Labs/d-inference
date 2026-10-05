package memory_test

import (
	"testing"
	"time"

	memoryhistory "github.com/eigeninference/d-inference/coordinator/internal/store/memoryhistory"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPruneCapsSlicesAtMaxEntries(t *testing.T) {
	s := memoryhistory.New()
	const maxEntries = 100

	// Overfill each append-only slice.
	for i := 0; i < maxEntries*3; i++ {
		s.Usage = append(s.Usage, store.UsageRecord{RequestID: "r", PromptTokens: i})
		s.LedgerEntries = append(s.LedgerEntries, store.LedgerEntry{ID: int64(i)})
		s.ProviderEarnings = append(s.ProviderEarnings, store.ProviderEarning{ID: int64(i)})
	}

	s.Prune(maxEntries)

	if got := len(s.Usage); got != maxEntries {
		t.Errorf("Usage len = %d, want %d", got, maxEntries)
	}
	if got := len(s.LedgerEntries); got != maxEntries {
		t.Errorf("LedgerEntries len = %d, want %d", got, maxEntries)
	}
	if got := len(s.ProviderEarnings); got != maxEntries {
		t.Errorf("ProviderEarnings len = %d, want %d", got, maxEntries)
	}

	// The kept entries should be the MOST RECENT ones, preserving order.
	if s.Usage[0].PromptTokens != maxEntries*3-maxEntries {
		t.Errorf("Usage[0] = %d, want oldest-kept = %d",
			s.Usage[0].PromptTokens, maxEntries*3-maxEntries)
	}
	if s.Usage[maxEntries-1].PromptTokens != maxEntries*3-1 {
		t.Errorf("Usage[last] = %d, want %d", s.Usage[maxEntries-1].PromptTokens, maxEntries*3-1)
	}
}

func TestPruneBelowCapNoop(t *testing.T) {
	s := memoryhistory.New()
	for i := 0; i < 5; i++ {
		s.Usage = append(s.Usage, store.UsageRecord{PromptTokens: i})
	}
	s.Prune(100)
	if got := len(s.Usage); got != 5 {
		t.Errorf("Usage len = %d, want 5 (no prune below cap)", got)
	}
}

func TestPruneDeletesExpiredDeviceCodes(t *testing.T) {
	s := memoryhistory.New()
	past := time.Now().Add(-time.Hour)
	future := time.Now().Add(time.Hour)

	s.DeviceCodesByCode["expired"] = &store.DeviceCode{DeviceCode: "expired", UserCode: "EXP", ExpiresAt: past}
	s.DeviceCodesByUserCode["EXP"] = s.DeviceCodesByCode["expired"]
	s.DeviceCodesByCode["fresh"] = &store.DeviceCode{DeviceCode: "fresh", UserCode: "FRS", ExpiresAt: future}
	s.DeviceCodesByUserCode["FRS"] = s.DeviceCodesByCode["fresh"]

	s.Prune(0) // 0 -> DefaultPruneMaxEntries

	if _, ok := s.DeviceCodesByCode["expired"]; ok {
		t.Error("expired device code should be deleted")
	}
	if _, ok := s.DeviceCodesByUserCode["EXP"]; ok {
		t.Error("expired user code should be deleted")
	}
	if _, ok := s.DeviceCodesByCode["fresh"]; !ok {
		t.Error("fresh device code should be kept")
	}
}

func TestPruneDefaultMaxEntries(t *testing.T) {
	s := memoryhistory.New()
	// Single entry, call with 0 -> should use DefaultPruneMaxEntries and be a no-op.
	s.Usage = append(s.Usage, store.UsageRecord{})
	s.Prune(0)
	if len(s.Usage) != 1 {
		t.Errorf("Usage len = %d, want 1", len(s.Usage))
	}
}
