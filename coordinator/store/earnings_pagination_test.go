package store

import (
	"fmt"
	"testing"
	"time"
)

func TestAccountEarningsPageUsesIDToBreakTimestampTies(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			accountID := uniqueID("earnings-page-account")
			createdAt := time.Now().UTC().Truncate(time.Microsecond)
			const total = 7

			for i := 0; i < total; i++ {
				if err := st.RecordProviderEarning(&ProviderEarning{
					AccountID:      accountID,
					ProviderID:     "provider-page",
					ProviderKey:    "provider-key-page",
					JobID:          fmt.Sprintf("%s-job-%d", accountID, i),
					Model:          "qwen3.5-9b",
					AmountMicroUSD: 1,
					CreatedAt:      createdAt,
				}); err != nil {
					t.Fatalf("record earning %d: %v", i, err)
				}
			}

			var (
				cursor *ProviderEarningsCursor
				got    []string
			)
			for {
				page, err := st.GetAccountEarningsPage(accountID, 3, cursor)
				if err != nil {
					t.Fatalf("get page: %v", err)
				}
				for _, earning := range page.Earnings {
					got = append(got, earning.JobID)
				}
				if page.Next == nil {
					break
				}
				if cursor != nil &&
					!page.Next.CreatedAt.Before(cursor.CreatedAt) &&
					page.Next.ID >= cursor.ID {
					t.Fatalf("cursor did not move backwards: previous=%+v next=%+v", cursor, page.Next)
				}
				cursor = page.Next
			}

			if len(got) != total {
				t.Fatalf("paged rows = %d, want %d: %v", len(got), total, got)
			}
			for i, jobID := range got {
				want := fmt.Sprintf("%s-job-%d", accountID, total-1-i)
				if jobID != want {
					t.Fatalf("row %d = %q, want %q (all rows: %v)", i, jobID, want, got)
				}
			}
		})
	}
}

func TestAccountEarningsWindowsUseCompleteRowsAndExcludeRewardsFromJobs(t *testing.T) {
	for backend, st := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			accountID := uniqueID("earnings-window-account")
			now := time.Now().UTC()
			inputs := []struct {
				age    time.Duration
				model  string
				amount int64
			}{
				{age: time.Hour, model: "qwen3.5-9b", amount: 100},
				{age: 2 * time.Hour, model: "base_reward", amount: 50},
				{age: 48 * time.Hour, model: "qwen3.5-9b", amount: 200},
				{age: 72 * time.Hour, model: "base_reward", amount: 30},
				{age: 8 * 24 * time.Hour, model: "qwen3.5-9b", amount: 999},
			}
			for i, input := range inputs {
				if err := st.RecordProviderEarning(&ProviderEarning{
					AccountID:      accountID,
					ProviderID:     "provider-window",
					ProviderKey:    "provider-key-window",
					JobID:          fmt.Sprintf("%s-window-%d", accountID, i),
					Model:          input.model,
					AmountMicroUSD: input.amount,
					CreatedAt:      now.Add(-input.age),
				}); err != nil {
					t.Fatalf("record window earning %d: %v", i, err)
				}
			}

			windows, err := st.GetAccountEarningsWindows(
				accountID,
				now.Add(-24*time.Hour),
				now.Add(-7*24*time.Hour),
			)
			if err != nil {
				t.Fatalf("get windows: %v", err)
			}
			if windows.Last24hMicroUSD != 150 || windows.Last24hJobs != 1 {
				t.Fatalf("24h window = %+v, want money=150 jobs=1", windows)
			}
			if windows.Last7dMicroUSD != 380 || windows.Last7dJobs != 2 {
				t.Fatalf("7d window = %+v, want money=380 jobs=2", windows)
			}
		})
	}
}
