package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

func TestNetworkModelEarningsSettledWindowAcrossAccounts(t *testing.T) {
	start := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(7 * 24 * time.Hour)
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			rows := []ProviderEarning{
				{AccountID: "one", Model: "a", JobID: "one", AmountMicroUSD: 10, CreatedAt: start},
				{AccountID: "two", Model: "a", JobID: "two", AmountMicroUSD: 20, CreatedAt: start.Add(time.Hour)},
				{AccountID: "two", Model: "b", JobID: "three", AmountMicroUSD: 50, CreatedAt: end.Add(-time.Second)},
				{Model: "a", JobID: "old", AmountMicroUSD: 900, CreatedAt: start.Add(-time.Nanosecond)},
				{Model: "a", JobID: "future", AmountMicroUSD: 900, CreatedAt: end},
				{Model: "base_reward", JobID: "reward", AmountMicroUSD: 900, CreatedAt: start},
				{Model: "", JobID: "unknown", AmountMicroUSD: 900, CreatedAt: start},
				{Model: "a", JobID: "zero", AmountMicroUSD: 0, CreatedAt: start},
				{Model: "a", JobID: "negative", AmountMicroUSD: -5, CreatedAt: start},
			}
			for i := range rows {
				if err := st.RecordProviderEarning(&rows[i]); err != nil {
					t.Fatal(err)
				}
			}
			reader, ok := As[NetworkModelEarningsReader](NewCached(st, CacheConfig{}))
			if !ok {
				t.Fatal("cache decorator hid aggregate capability")
			}
			got, err := reader.NetworkModelEarnings(context.Background(), start, end)
			if err != nil {
				t.Fatal(err)
			}
			if want := map[string]int64{"a": 30, "b": 50}; !reflect.DeepEqual(got, want) {
				t.Fatalf("got %v, want %v", got, want)
			}
			if _, err := reader.NetworkModelEarnings(context.Background(), start, start); err == nil {
				t.Fatal("invalid window accepted")
			}
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			if _, err := reader.NetworkModelEarnings(ctx, start, end); err == nil {
				t.Fatal("cancelled query returned earnings")
			}
		})
	}
}

func TestNetworkModelEarningsDatabaseFailureIsUnavailable(t *testing.T) {
	st := testPostgresStore(t)
	st.Close()
	now := time.Now()
	if _, err := st.NetworkModelEarnings(context.Background(), now.Add(-7*24*time.Hour), now); err == nil {
		t.Fatal("failed query returned successful zero totals")
	}
}
