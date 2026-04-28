package leaderboard

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/analytics/internal/pseudonym"
)

func fixedNow() time.Time {
	return time.Date(2026, time.April, 15, 12, 0, 0, 0, time.UTC)
}

func TestMemoryStoreOverview(t *testing.T) {
	store := NewMemoryStoreWithClock(2*time.Minute, fixedNow)

	overview, err := store.Overview(context.Background())
	if err != nil {
		t.Fatalf("Overview: %v", err)
	}

	if overview.RegisteredNodes != 5 {
		t.Fatalf("RegisteredNodes = %d, want 5", overview.RegisteredNodes)
	}
	if overview.ActiveNodes != 4 {
		t.Fatalf("ActiveNodes = %d, want 4", overview.ActiveNodes)
	}
	if overview.LinkedAccounts != 4 {
		t.Fatalf("LinkedAccounts = %d, want 4", overview.LinkedAccounts)
	}
	if overview.TotalEarnedMicroUSD != 44_600_000 {
		t.Fatalf("TotalEarnedMicroUSD = %d, want 44600000", overview.TotalEarnedMicroUSD)
	}
	if overview.Jobs24h != 4 {
		t.Fatalf("Jobs24h = %d, want 4", overview.Jobs24h)
	}
}

func TestServiceAccountLeaderboard(t *testing.T) {
	store := NewMemoryStoreWithClock(2*time.Minute, fixedNow)
	aliaser, err := pseudonym.NewGenerator("secret")
	if err != nil {
		t.Fatalf("NewGenerator: %v", err)
	}

	service := NewService(store, aliaser, func() time.Time {
		return fixedNow()
	})

	board, err := service.EarningsLeaderboard(context.Background(), Query{
		Scope:  ScopeAccount,
		Window: Window7d,
		Limit:  10,
	})
	if err != nil {
		t.Fatalf("EarningsLeaderboard: %v", err)
	}

	if len(board.Entries) != 4 {
		t.Fatalf("len(entries) = %d, want 4", len(board.Entries))
	}
	if board.Entries[0].EarnedMicroUSD != 17_600_000 {
		t.Fatalf("top earned_micro_usd = %d, want 17600000", board.Entries[0].EarnedMicroUSD)
	}
	if board.Entries[0].NodeCount != 2 {
		t.Fatalf("top node_count = %d, want 2", board.Entries[0].NodeCount)
	}
	if board.Entries[0].AvgPerJobUSD != "5.866667" {
		t.Fatalf("top avg_per_job_usd = %q, want %q", board.Entries[0].AvgPerJobUSD, "5.866667")
	}
	if board.Entries[0].Alias == "" {
		t.Fatal("expected alias to be populated")
	}
}

func TestServiceNodeLeaderboard(t *testing.T) {
	store := NewMemoryStoreWithClock(2*time.Minute, fixedNow)
	aliaser, err := pseudonym.NewGenerator("secret")
	if err != nil {
		t.Fatalf("NewGenerator: %v", err)
	}

	service := NewService(store, aliaser, fixedNow)
	board, err := service.EarningsLeaderboard(context.Background(), Query{
		Scope:  ScopeNode,
		Window: Window7d,
		Limit:  10,
	})
	if err != nil {
		t.Fatalf("EarningsLeaderboard: %v", err)
	}

	if len(board.Entries) != 5 {
		t.Fatalf("len(entries) = %d, want 5", len(board.Entries))
	}
	if board.Entries[0].EarnedMicroUSD != 14_300_000 {
		t.Fatalf("top earned_micro_usd = %d, want 14300000", board.Entries[0].EarnedMicroUSD)
	}
	if board.Entries[0].NodeCount != 1 {
		t.Fatalf("top node_count = %d, want 1", board.Entries[0].NodeCount)
	}
}
