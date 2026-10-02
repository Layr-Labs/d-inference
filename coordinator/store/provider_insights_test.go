package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

func TestProviderInsightsAccountWindowAndRewardSeparation(t *testing.T) {
	start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(24 * time.Hour)
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			rows := []ProviderEarning{
				{AccountID: "owner", ProviderID: "mac", Model: "model", JobID: "one", AmountMicroUSD: 10, PromptTokens: 40, CompletionTokens: 20, CreatedAt: start},
				{AccountID: "owner", ProviderID: "mac", Model: "model", JobID: "two", AmountMicroUSD: 15, PromptTokens: 50, CompletionTokens: 30, CreatedAt: start.Add(time.Hour).In(time.FixedZone("west", -7*3600))},
				{AccountID: "owner", Model: "base_reward", JobID: "reward", AmountMicroUSD: 900, PromptTokens: 999, CompletionTokens: 999, CreatedAt: start.Add(time.Hour)},
				{AccountID: "other", Model: "model", JobID: "other", AmountMicroUSD: 100000, CreatedAt: start},
				{AccountID: "owner", Model: "model", JobID: "old", AmountMicroUSD: 100000, CreatedAt: start.Add(-time.Nanosecond)},
				{AccountID: "owner", Model: "model", JobID: "future", AmountMicroUSD: 100000, CreatedAt: end},
			}
			for i := range rows {
				if err := st.RecordProviderEarning(&rows[i]); err != nil {
					t.Fatal(err)
				}
			}
			reader, ok := As[ProviderInsightsReader](NewCached(st, CacheConfig{}))
			if !ok {
				t.Fatal("capability hidden by cache decorator")
			}
			got, err := reader.ProviderInsightGroups(context.Background(), "owner", start, end)
			if err != nil {
				t.Fatal(err)
			}
			want := []ProviderInsightGroup{
				{Day: "2026-10-01", Model: "base_reward", ProviderInsightAmounts: ProviderInsightAmounts{BaseRewardMicroUSD: 900}},
				{Day: "2026-10-01", Model: "model", ProviderID: "mac", ProviderInsightAmounts: ProviderInsightAmounts{WorkMicroUSD: 25, Jobs: 2, PromptTokens: 90, CompletionTokens: 50}},
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("got %+v; want %+v", got, want)
			}
			if _, err := reader.ProviderInsightGroups(context.Background(), "owner", start, start.Add(32*24*time.Hour)); err == nil {
				t.Fatal("unbounded window accepted")
			}
		})
	}
}

func TestProviderInsightsDoesNotTruncateToRecentEarningsPage(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			account := uniqueID("insights")
			want := seedAccountEarnings(t, st, account, 6000, now)
			reader, _ := As[ProviderInsightsReader](st)
			groups, err := reader.ProviderInsightGroups(context.Background(), account, now.Add(-7*24*time.Hour), now)
			if err != nil {
				t.Fatal(err)
			}
			var total ProviderInsightAmounts
			for _, g := range groups {
				total.Add(g.ProviderInsightAmounts)
			}
			if total.Jobs != 6000 || total.WorkMicroUSD != want.Last7dMicroUSD || total.CompletionTokens != 12000 {
				t.Fatalf("truncated totals: %+v", total)
			}
		})
	}
}

func TestAccountEarningsSummaryDatabaseFailureIsNotZero(t *testing.T) {
	st := testPostgresStore(t)
	st.Close()
	if _, err := st.GetAccountEarningsSummary("owner"); err == nil {
		t.Fatal("closed database returned successful zero totals")
	}
}
