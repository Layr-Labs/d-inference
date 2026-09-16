package memory

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func TestPruneCapsSlicesAtMaxEntries(t *testing.T) {
	s := New(contracts.Config{})
	const maxEntries = 100

	// Overfill each append-only slice.
	for i := 0; i < maxEntries*3; i++ {
		s.usage = append(s.usage, contracts.UsageRecord{RequestID: "r", PromptTokens: i})
		s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{ID: int64(i)})
		s.providerEarnings = append(s.providerEarnings, contracts.ProviderEarning{ID: int64(i)})
		s.providerPayouts = append(s.providerPayouts, contracts.ProviderPayout{ID: int64(i)})
		s.payments = append(s.payments, contracts.PaymentRecord{TxHash: "t"})
	}

	s.Prune(maxEntries)

	if got := len(s.usage); got != maxEntries {
		t.Errorf("usage len = %d, want %d", got, maxEntries)
	}
	if got := len(s.ledgerEntries); got != maxEntries {
		t.Errorf("ledgerEntries len = %d, want %d", got, maxEntries)
	}
	if got := len(s.providerEarnings); got != maxEntries {
		t.Errorf("providerEarnings len = %d, want %d", got, maxEntries)
	}
	if got := len(s.providerPayouts); got != maxEntries {
		t.Errorf("providerPayouts len = %d, want %d", got, maxEntries)
	}
	if got := len(s.payments); got != maxEntries {
		t.Errorf("payments len = %d, want %d", got, maxEntries)
	}

	// The kept entries should be the MOST RECENT ones, preserving order.
	if s.usage[0].PromptTokens != maxEntries*3-maxEntries {
		t.Errorf("usage[0] = %d, want oldest-kept = %d",
			s.usage[0].PromptTokens, maxEntries*3-maxEntries)
	}
	if s.usage[maxEntries-1].PromptTokens != maxEntries*3-1 {
		t.Errorf("usage[last] = %d, want %d", s.usage[maxEntries-1].PromptTokens, maxEntries*3-1)
	}
}

func TestPruneBelowCapNoop(t *testing.T) {
	s := New(contracts.Config{})
	for i := 0; i < 5; i++ {
		s.usage = append(s.usage, contracts.UsageRecord{PromptTokens: i})
	}
	s.Prune(100)
	if got := len(s.usage); got != 5 {
		t.Errorf("usage len = %d, want 5 (no prune below cap)", got)
	}
}

func TestPruneDeletesExpiredDeviceCodes(t *testing.T) {
	s := New(contracts.Config{})
	past := time.Now().Add(-time.Hour)
	future := time.Now().Add(time.Hour)

	s.deviceCodesByCode["expired"] = &contracts.DeviceCode{DeviceCode: "expired", UserCode: "EXP", ExpiresAt: past}
	s.deviceCodesByUserCode["EXP"] = s.deviceCodesByCode["expired"]
	s.deviceCodesByCode["fresh"] = &contracts.DeviceCode{DeviceCode: "fresh", UserCode: "FRS", ExpiresAt: future}
	s.deviceCodesByUserCode["FRS"] = s.deviceCodesByCode["fresh"]

	s.Prune(0) // 0 -> DefaultPruneMaxEntries

	if _, ok := s.deviceCodesByCode["expired"]; ok {
		t.Error("expired device code should be deleted")
	}
	if _, ok := s.deviceCodesByUserCode["EXP"]; ok {
		t.Error("expired user code should be deleted")
	}
	if _, ok := s.deviceCodesByCode["fresh"]; !ok {
		t.Error("fresh device code should be kept")
	}
}

func TestPruneDefaultMaxEntries(t *testing.T) {
	s := New(contracts.Config{})
	// Single entry, call with 0 -> should use DefaultPruneMaxEntries and be a no-op.
	s.usage = append(s.usage, contracts.UsageRecord{})
	s.Prune(0)
	if len(s.usage) != 1 {
		t.Errorf("usage len = %d, want 1", len(s.usage))
	}
}
