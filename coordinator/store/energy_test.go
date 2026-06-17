package store

import (
	"testing"
	"time"
)

func TestProviderEnergyRoundTrip(t *testing.T) {
	st := NewMemory(Config{})

	rec := &ProviderEnergyRecord{
		ProviderID:       "prov-1",
		AccountID:        "acct-1",
		SerialNumber:     "C02XYZ",
		Model:            "qwen3.5-9b",
		ChipFamily:       "M4",
		ChipTier:         "Max",
		GPUCores:         40,
		CurrentWatts:     45.5,
		IdleWatts:        8.0,
		IdleJoules:       900,
		PrefillJoules:    300,
		DecodeJoules:     1500,
		LoadJoules:       120,
		CPUJoules:        400,
		GPUJoules:        2000,
		DRAMJoules:       500,
		PrefillTokens:    2000,
		DecodeTokens:     3000,
		WarmSeconds:      120,
		ModelLoads:       2,
		JPerPrefillToken: 0.05,
		JPerDecodeToken:  0.5,
	}
	if err := st.RecordProviderEnergy(rec); err != nil {
		t.Fatalf("RecordProviderEnergy: %v", err)
	}

	got := st.ProviderEnergySince(time.Time{})
	if len(got) != 1 {
		t.Fatalf("ProviderEnergySince returned %d records, want 1", len(got))
	}
	r := got[0]
	if r.ProviderID != "prov-1" || r.Model != "qwen3.5-9b" || r.ChipFamily != "M4" {
		t.Errorf("identity mismatch: %+v", r)
	}
	if r.DecodeJoules != 1500 || r.JPerDecodeToken != 0.5 || r.ModelLoads != 2 {
		t.Errorf("value mismatch: decodeJ=%v jPerDecode=%v loads=%d", r.DecodeJoules, r.JPerDecodeToken, r.ModelLoads)
	}
	if r.CreatedAt.IsZero() {
		t.Error("CreatedAt should be auto-populated")
	}

	// `since` in the future excludes the record.
	if n := len(st.ProviderEnergySince(time.Now().Add(time.Hour))); n != 0 {
		t.Errorf("future since returned %d records, want 0", n)
	}
}
