package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsCutoffPreservesNovember7PendingPayment(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		end := time.Date(2026, time.November, 8, 0, 0, 0, 0, time.UTC)
		lastDay := end.AddDate(0, 0, -1)
		f.optIn = lastDay.Add(12 * time.Hour)
		f.clock.Store(end.AddDate(0, 0, 10).UnixMicro())
		enrollment := f.enroll(t, "cutoff-session", "cutoff-owner", 70)
		pending := f.settle(t, enrollment.MachineID, lastDay)
		if pending.Status != earningsfloor.PoolExhausted || pending.DueMicroUSD != 11 {
			t.Fatalf("last eligible day should remain payable: %+v", pending)
		}
		f.fund(t, 100)
		paid := f.settle(t, enrollment.MachineID, lastDay)
		if paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 11 {
			t.Fatalf("cutoff erased an earlier earned reward: %+v", paid)
		}
		if replay := f.settle(t, enrollment.MachineID, lastDay); replay != paid {
			t.Fatalf("late retry changed the final receipt: %+v", replay)
		}
		for _, day := range []time.Time{end, end.AddDate(0, 0, 1)} {
			if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), enrollment.MachineID, day); err == nil {
				t.Fatalf("day on or after shared cutoff was accepted: %s", day)
			}
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 11 || f.backend.GetBalance("cutoff-owner") != 11 || f.backend.GetWithdrawableBalance("cutoff-owner") != 11 {
			t.Fatalf("cutoff or retry changed money: pool=%+v error=%v", pool, err)
		}
	})
}
