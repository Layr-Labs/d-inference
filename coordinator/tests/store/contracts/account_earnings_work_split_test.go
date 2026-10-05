package store_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func settleDrawFor(t *testing.T, s store.Store, acct, pk, epoch string, amount int64) bool {
	t.Helper()
	return settleFloorDraw(t, s, &store.ProviderFloorDraw{
		ProviderKey: pk, AccountID: acct, EpochID: epoch,
		AmountMicroUSD: amount, FloorMicroUSD: amount, UptimeFrac: 1, MemoryGB: 64,
	})
}

// W1: base reward = sum of settled draws; total and count keep their meaning.
func TestW1AccountSummaryBaseRewardEqualsSettledDraws(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-w1")
			pk := uniqueID("pk-w1")
			for i, amt := range []int64{300, 700} {
				if err := s.RecordProviderEarning(&store.ProviderEarning{
					AccountID: acct, ProviderID: "p", ProviderKey: pk,
					JobID: uniqueID("job"), Model: "model", AmountMicroUSD: amt,
					PromptTokens: 1, CompletionTokens: 2,
				}); err != nil {
					t.Fatalf("record %d: %v", i, err)
				}
			}
			if !settleDrawFor(t, s, acct, pk, "2026-01", 5_000) || !settleDrawFor(t, s, acct, pk, "2026-02", 7_000) {
				t.Fatal("draw not settled")
			}
			got, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if got.BaseRewardMicroUSD != 12_000 {
				t.Fatalf("BaseRewardMicroUSD = %d, want 12000", got.BaseRewardMicroUSD)
			}
			if got.TotalMicroUSD != 1_000+12_000 || got.Count != 2 {
				t.Fatalf("total=%d count=%d, want 13000 and 2", got.TotalMicroUSD, got.Count)
			}
		})
	}
}

// W2: CreditProviderAccount grows the column only for model base_reward.
func TestW2CreditProviderAccountBaseRewardOnly(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-w2")
			pk := uniqueID("pk-w2")
			if err := s.CreditProviderAccount(&store.ProviderEarning{
				AccountID: acct, ProviderID: "p", ProviderKey: pk, JobID: uniqueID("job"),
				Model: "qwen3.5-9b", AmountMicroUSD: 400,
			}); err != nil {
				t.Fatal(err)
			}
			sum, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if sum.BaseRewardMicroUSD != 0 || sum.TotalMicroUSD != 400 {
				t.Fatalf("after inference credit: %+v, want base 0 total 400", sum)
			}
			if err := s.CreditProviderAccount(&store.ProviderEarning{
				AccountID: acct, ProviderID: "p", ProviderKey: pk, JobID: uniqueID("job"),
				Model: "base_reward", AmountMicroUSD: 900,
			}); err != nil {
				t.Fatal(err)
			}
			sum, err = s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if sum.BaseRewardMicroUSD != 900 || sum.TotalMicroUSD != 1_300 {
				t.Fatalf("after base_reward credit: %+v, want base 900 total 1300", sum)
			}
		})
	}
}

// W3: a duplicate draw and a zero-amount draw leave the column unchanged.
func TestW3DuplicateAndZeroDrawLeaveBaseRewardUnchanged(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-w3")
			pk := uniqueID("pk-w3")
			if !settleDrawFor(t, s, acct, pk, "2026-03", 2_500) {
				t.Fatal("first draw not settled")
			}
			if settleDrawFor(t, s, acct, pk, "2026-03", 2_500) {
				t.Fatal("duplicate draw reported settled")
			}
			settleDrawFor(t, s, acct, pk, "2026-04", 0)
			sum, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if sum.BaseRewardMicroUSD != 2_500 || sum.TotalMicroUSD != 2_500 {
				t.Fatalf("summary %+v, want base 2500 total 2500", sum)
			}
		})
	}
}

// RecordProviderEarning adds base_reward rows to the column and nothing else.
func TestRecordProviderEarningBaseRewardColumn(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			acct := uniqueID("acct-rpe")
			for i, e := range []store.ProviderEarning{
				{AccountID: acct, ProviderID: "p", ProviderKey: "k", JobID: uniqueID("job"), Model: "qwen", AmountMicroUSD: 40},
				{AccountID: acct, ProviderKey: "k", JobID: uniqueID("floor"), Model: "base_reward", AmountMicroUSD: 900},
			} {
				if err := s.RecordProviderEarning(&e); err != nil {
					t.Fatalf("record %d: %v", i, err)
				}
			}
			got, err := s.GetAccountEarningsSummary(acct)
			if err != nil {
				t.Fatal(err)
			}
			if got.BaseRewardMicroUSD != 900 || got.TotalMicroUSD != 940 || got.Count != 1 {
				t.Fatalf("base=%d total=%d count=%d, want 900, 940, 1", got.BaseRewardMicroUSD, got.TotalMicroUSD, got.Count)
			}
		})
	}
}
