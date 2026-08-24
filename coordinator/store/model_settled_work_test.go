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
			recoverableJob := uniqueID("recoverable-job")
			unattributedJob := uniqueID("unattributed-job")
			conflictingJob := uniqueID("conflicting-job")

			entries := []ProviderEarning{
				{JobID: uniqueID("job"), Model: "build-b", PublicModel: modelB, AmountMicroUSD: 500_000, PromptTokens: 10, CompletionTokens: 5, CreatedAt: start.Add(10 * time.Minute)},
				{JobID: uniqueID("job"), Model: "build-a-v2", PublicModel: modelA, AmountMicroUSD: 1_250_000, PromptTokens: 20, CompletionTokens: 8, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a-v1", PublicModel: modelA, AmountMicroUSD: 750_000, PromptTokens: 30, CompletionTokens: 7, CreatedAt: start.Add(30 * time.Minute)},
				{JobID: recoverableJob, Model: legacyBuild, AmountMicroUSD: 125_000, PromptTokens: 2, CompletionTokens: 1, CreatedAt: start.Add(20 * time.Minute)},
				{JobID: unattributedJob, Model: legacyBuild, AmountMicroUSD: 25_000, PromptTokens: 1, CompletionTokens: 1, CreatedAt: start.Add(21 * time.Minute)},
				{JobID: conflictingJob, Model: legacyBuild, AmountMicroUSD: 10_000, PromptTokens: 1, CompletionTokens: 1, CreatedAt: start.Add(22 * time.Minute)},
				{JobID: uniqueID("job"), Model: "base_reward", AmountMicroUSD: 99_000_000, PromptTokens: 999, CompletionTokens: 999, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 0, PromptTokens: 999, CompletionTokens: 999, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: -1, PromptTokens: 999, CompletionTokens: 999, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 9_000_000, PromptTokens: -1, CompletionTokens: 1, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 8_000_000, PromptTokens: 1, CompletionTokens: -1, CreatedAt: start},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 88_000_000, CreatedAt: start.Add(-time.Second)},
				{JobID: uniqueID("job"), Model: "build-a", PublicModel: modelA, AmountMicroUSD: 77_000_000, CreatedAt: end},
				{JobID: uniqueID("job"), Model: "", AmountMicroUSD: 66_000_000, CreatedAt: start},
			}
			for i := range entries {
				if err := st.RecordProviderEarning(&entries[i]); err != nil {
					t.Fatalf("RecordProviderEarning: %v", err)
				}
			}
			st.RecordUsageFullWithPublicModel(
				"provider", "consumer", "", legacyBuild, modelA, recoverableJob,
				2, 1, 125_000, nil,
			)
			st.RecordUsageFullWithPublicModel(
				"provider", "consumer", "", legacyBuild, modelA, conflictingJob,
				1, 1, 10_000, nil,
			)
			st.RecordUsageFullWithPublicModel(
				"provider", "consumer", "", legacyBuild, modelB, conflictingJob,
				1, 1, 10_000, nil,
			)

			got, err := st.ModelSettledWorkTotals(start, end)
			if err != nil {
				t.Fatalf("ModelSettledWorkTotals: %v", err)
			}
			want := []ModelSettledWorkTotal{
				{
					PublicModel:        "",
					WorkPayoutMicroUSD: 35_000,
					PromptTokens:       2,
					CompletionTokens:   2,
					Jobs:               2,
				},
				{
					PublicModel:        modelA,
					WorkPayoutMicroUSD: 2_125_000,
					PromptTokens:       52,
					CompletionTokens:   16,
					Jobs:               3,
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
			if got[1].PaidTokens() != 68 {
				t.Fatalf("PaidTokens = %d, want 68", got[1].PaidTokens())
			}
		})
	}
}
