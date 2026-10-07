package store_test

import (
	"context"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAutopilotBonusAtomicAccounting(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			d := store.ProviderFloorDraw{ProviderKey: uniqueID("key"), AccountID: uniqueID("account"), EpochID: "autopilot", AmountMicroUSD: 1009, AutopilotBonusMicroUSD: 100}
			batch, _ := store.As[store.FloorDrawBatchStore](s)
			items := []store.FloorDrawBatchItem{{SessionID: "session", Draw: d}}
			calls := 0
			result, err := batch.SettleProviderFloorDrawBatch(ctx, items, func(int) bool { calls++; return calls == 1 })
			if err != nil || result.Committed {
				t.Fatalf("late rejection: %+v %v", result, err)
			}
			draws, err := s.ListFloorDrawsForEpoch(ctx, d.EpochID)
			earnings, _ := s.GetAccountEarnings(d.AccountID, 10)
			if err != nil || len(draws) != 0 || len(earnings) != 0 || s.GetBalance(d.AccountID) != 0 || len(s.LedgerHistory(d.AccountID)) != 0 {
				t.Fatalf("rollback left money: %+v %+v %v", draws, earnings, err)
			}
			if !settleFloorDraw(t, s, &d) || settleFloorDraw(t, s, &d) {
				t.Fatal("not exactly once")
			}
			if s.GetBalance(d.AccountID) != 1109 || s.GetWithdrawableBalance(d.AccountID) != 1109 {
				t.Fatal("missing base or bonus credit")
			}
			history := s.LedgerHistory(d.AccountID)
			if len(history) != 2 {
				t.Fatalf("ledger: %+v", history)
			}
			var baseID, bonusID int64
			for _, row := range history {
				switch row.Type {
				case store.LedgerFloorDraw:
					baseID = row.ID
					if row.AmountMicroUSD != 1009 || row.BalanceAfter != 1009 {
						t.Fatalf("base ledger: %+v", row)
					}
				case store.LedgerAutopilotBonus:
					bonusID = row.ID
					if row.AmountMicroUSD != 100 || row.BalanceAfter != 1109 {
						t.Fatalf("bonus ledger: %+v", row)
					}
				default:
					t.Fatalf("unexpected ledger: %+v", row)
				}
			}
			if baseID == 0 || bonusID <= baseID {
				t.Fatalf("ledger IDs do not follow the base-then-bonus balance changes: %+v", history)
			}
			draws, err = s.ListFloorDrawsForEpoch(ctx, d.EpochID)
			if err != nil || len(draws) != 1 || draws[0].AmountMicroUSD != 1009 || draws[0].AutopilotBonusMicroUSD != 100 {
				t.Fatalf("audit: %+v %v", draws, err)
			}
			used, _ := s.SumFloorDrawsForEpoch(ctx, d.EpochID)
			if used != 1009 {
				t.Fatalf("base pot charged bonus: %d", used)
			}
			summary, err := s.GetAccountEarningsSummary(d.AccountID)
			if err != nil || summary.TotalMicroUSD != 1109 || summary.Count != 0 {
				t.Fatalf("summary: %+v %v", summary, err)
			}
			organic, err := s.SumProviderEarningsByKey(ctx, d.ProviderKey, time.Now().Add(-time.Hour), time.Now().Add(time.Hour))
			if err != nil || organic != 0 {
				t.Fatalf("bonus counted as work: %d %v", organic, err)
			}
		})
	}
}

func TestAutopilotBonusRejectsInvalidAmounts(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			batch, _ := store.As[store.FloorDrawBatchStore](s)
			for _, amount := range [][2]int64{{100, -1}, {100, 11}, {100, 9}, {0, 1}, {math.MaxInt64, math.MaxInt64 / 10}} {
				d := store.ProviderFloorDraw{ProviderKey: "key", AccountID: "account", EpochID: "invalid-bonus", AmountMicroUSD: amount[0], AutopilotBonusMicroUSD: amount[1]}
				r, err := batch.SettleProviderFloorDrawBatch(context.Background(), []store.FloorDrawBatchItem{{SessionID: "session", Draw: d}}, func(int) bool { return true })
				if err == nil || r.Committed {
					t.Fatalf("invalid amounts accepted: %v %+v %v", amount, r, err)
				}
			}
			if s.GetBalance("account") != 0 {
				t.Fatal("invalid draw credited")
			}
		})
	}
}
