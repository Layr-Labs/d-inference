package store

import (
	"reflect"
	"testing"
	"time"
)

func TestModelSettledWorkTotals(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			start := time.Now().UTC().Truncate(time.Second)
			end := start.Add(time.Hour)
			modelA := uniqueID("a-model")
			modelB := uniqueID("b-model")
			legacyBuild := uniqueID("legacy-build")

			entries := []ProviderEarning{
				{JobID: uniqueID("job"), Model: "build-b", PublicModel: modelB, AmountMicroUSD: 500_000, PromptTokens: 10, CompletionTokens: 5, CreatedAt: start.Add(10 * time.Minute)},
				{JobID: uniqueID("job"), Model: "build-a-v2", PublicModel: modelA, AmountMicroUSD: 1_250_000, PromptTokens: 20, CompletionTokens: 8, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a-v1", PublicModel: modelA, AmountMicroUSD: 750_000, PromptTokens: 30, CompletionTokens: 7, CreatedAt: start.Add(30 * time.Minute)},
				{JobID: uniqueID("job"), Model: legacyBuild, AmountMicroUSD: 125_000, PromptTokens: 2, CompletionTokens: 1, CreatedAt: start.Add(20 * time.Minute)},
				{JobID: uniqueID("job"), Model: "base_reward", AmountMicroUSD: 99_000_000, PromptTokens: 999, CompletionTokens: 999, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 0, PromptTokens: 999, CompletionTokens: 999, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: -1, PromptTokens: 999, CompletionTokens: 999, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 88_000_000, CreatedAt: start.Add(-time.Second)},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 77_000_000, CreatedAt: end},
				{JobID: uniqueID("job"), Model: "", AmountMicroUSD: 66_000_000, CreatedAt: start},
			}
			for i := range entries {
				if err := st.RecordProviderEarning(&entries[i]); err != nil {
					t.Fatalf("RecordProviderEarning: %v", err)
				}
			}

			got, err := st.ModelSettledWorkTotals(start, end)
			if err != nil {
				t.Fatalf("ModelSettledWorkTotals: %v", err)
			}
			want := []ModelSettledWorkTotal{
				{
					PublicModel:        "",
					WorkPayoutMicroUSD: 125_000,
					PromptTokens:       2,
					CompletionTokens:   1,
					Jobs:               1,
				},
				{
					PublicModel:        modelA,
					WorkPayoutMicroUSD: 2_000_000,
					PromptTokens:       50,
					CompletionTokens:   15,
					Jobs:               2,
				},
				{
					PublicModel:        modelB,
					WorkPayoutMicroUSD: 500_000,
					PromptTokens:       10,
					CompletionTokens:   5,
					Jobs:               1,
				},
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("totals = %+v, want %+v", got, want)
			}
			if got[1].PaidTokens() != 65 {
				t.Fatalf("PaidTokens = %d, want 65", got[1].PaidTokens())
			}
		})
	}
}
