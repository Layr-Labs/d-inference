package store

import (
	"testing"
	"time"
)

func TestProviderEarningsWindowsIncludesAllRowsAndExcludesBaseRewardJobs(t *testing.T) {
	s := NewMemory(Config{})
	now := time.Now()
	cutoff24h := now.Add(-24 * time.Hour)
	cutoff7d := now.Add(-7 * 24 * time.Hour)

	rows := []ProviderEarning{
		{AccountID: "acct-windows", Model: "qwen", AmountMicroUSD: 100, CreatedAt: now.Add(-time.Hour)},
		{AccountID: "acct-windows", Model: "base_reward", AmountMicroUSD: 200, CreatedAt: now.Add(-2 * time.Hour)},
		{AccountID: "acct-windows", Model: "qwen", AmountMicroUSD: 300, CreatedAt: now.Add(-48 * time.Hour)},
		{AccountID: "acct-windows", Model: "base_reward", AmountMicroUSD: 400, CreatedAt: now.Add(-48 * time.Hour)},
		{AccountID: "acct-windows", Model: "qwen", AmountMicroUSD: 500, CreatedAt: now.Add(-8 * 24 * time.Hour)},
		{AccountID: "other-account", Model: "qwen", AmountMicroUSD: 600, CreatedAt: now.Add(-time.Hour)},
	}
	for i := range rows {
		if err := s.RecordProviderEarning(&rows[i]); err != nil {
			t.Fatalf("RecordProviderEarning: %v", err)
		}
	}

	windows, err := s.GetAccountEarningsWindows("acct-windows", cutoff24h, cutoff7d)
	if err != nil {
		t.Fatalf("GetAccountEarningsWindows: %v", err)
	}

	if windows.Last24hMicroUSD != 300 || windows.Last24hJobs != 1 {
		t.Fatalf("last 24h = %+v, want money=300 jobs=1", windows)
	}
	if windows.Last7dMicroUSD != 1000 || windows.Last7dJobs != 2 {
		t.Fatalf("last 7d = %+v, want money=1000 jobs=2", windows)
	}
}
