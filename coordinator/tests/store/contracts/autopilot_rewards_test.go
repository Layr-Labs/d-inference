package store_test

import (
	"errors"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsDailyShortfallAndAccounting(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		enrollment := f.enroll(t, "provider", "owner", 70)
		if enrollment.DailyFloorMicroUSD != 11 {
			t.Fatalf("daily floor = %d, want 11", enrollment.DailyFloorMicroUSD)
		}
		f.fund(t, 100)
		for offset, actual := range []int64{8, 10, 12} {
			day := enrollment.NextDay.AddDate(0, 0, offset)
			f.earning(t, "provider", "owner", actual, day.Add(14*time.Hour))
			receipt := f.settle(t, enrollment.MachineID, day)
			want := max(int64(0), 11-actual)
			status := earningsfloor.Paid
			if want == 0 {
				status = earningsfloor.Zero
			}
			if receipt.FloorMicroUSD != 11 || receipt.InferenceMicroUSD != actual || receipt.DueMicroUSD != want || receipt.AmountMicroUSD != want || receipt.Status != status {
				t.Fatalf("day %d receipt = %+v, want floor11 actual%d paid%d", offset, receipt, actual, want)
			}
			if replay := f.settle(t, enrollment.MachineID, day); replay != receipt {
				t.Fatalf("receipt replay changed: %+v -> %+v", receipt, replay)
			}
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 4 {
			t.Fatalf("pool = %+v, %v", pool, err)
		}
		if balance, withdrawable := f.backend.GetBalanceWithWithdrawable("owner"); balance != 4 || withdrawable != 4 {
			t.Fatalf("top-up balance/withdrawable = %d/%d, want 4/4", balance, withdrawable)
		}
		ledger := f.backend.LedgerHistory("owner")
		if len(ledger) != 2 {
			t.Fatalf("ledger rows = %d, want two positive credits", len(ledger))
		}
		earnings, err := f.backend.GetAccountEarnings("owner", 100)
		if err != nil {
			t.Fatal(err)
		}
		var rewards int
		for _, earning := range earnings {
			if earning.Model != "base_reward" {
				continue
			}
			rewards++
			if earning.ProviderKey != store.MachineFloorKey(enrollment.MachineID) || earning.PromptTokens != 0 || earning.CompletionTokens != 0 {
				t.Fatalf("non-inference top-up earning = %+v", earning)
			}
			found := false
			for _, entry := range ledger {
				if entry.Reference == earning.JobID && entry.Type == store.LedgerAutopilotFloor && entry.AmountMicroUSD == earning.AmountMicroUSD {
					found = true
				}
			}
			if !found {
				t.Fatalf("top-up earning has no matching unique ledger: %+v", earning)
			}
		}
		if rewards != 2 {
			t.Fatalf("reward earnings = %d, want two", rewards)
		}
		summary, err := f.backend.GetAccountEarningsSummary("owner")
		if err != nil || summary.TotalMicroUSD != 104 || summary.Count != 4 || summary.PromptTokens != 8 || summary.CompletionTokens != 12 {
			t.Fatalf("earnings summary = %+v, %v", summary, err)
		}
		rows := mustLeaderboard(t, f.backend, store.LeaderboardEarnings, time.Time{}, 100)
		row, found := findRow(rows, "owner")
		if !found || row.WorkEarningsMicroUSD != 100 || row.RewardEarningsMicroUSD != 4 || row.EarningsMicroUSD != 104 || row.Jobs != 4 {
			t.Fatalf("leaderboard double-counted or omitted reward: %+v", rows)
		}
		totals, err := f.backend.NetworkTotals(time.Time{})
		if err != nil || totals.WorkEarningsMicroUSD != 100 || totals.RewardEarningsMicroUSD != 4 || totals.EarningsMicroUSD != 104 || totals.Jobs != 4 {
			t.Fatalf("network totals = %+v, %v", totals, err)
		}
	})
}

func TestAutopilotRewardsMiddayEnrollmentUsesWholeDay(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		f.observe(t, store.MachineObservation{SessionID: "session", AccountID: "owner", SEKey: "se", At: f.start})
		f.consent(t, "session", "owner", false, f.start)
		f.earning(t, "session", "owner", 62, f.optIn.Add(-48*time.Hour))
		f.earning(t, "session", "owner", 8, floorpolicy.Day(f.optIn).Add(8*time.Hour))
		enrollment := f.consent(t, "session", "owner", true, f.optIn)
		f.fund(t, 3)
		receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay)
		if enrollment.SevenDayEarningsMicroUSD != 70 || receipt.FloorMicroUSD != 11 || receipt.InferenceMicroUSD != 8 || receipt.AmountMicroUSD != 3 {
			t.Fatalf("midday opt-in was prorated or earlier same-day earnings omitted: %+v %+v", enrollment, receipt)
		}
	})
}

func TestAutopilotRewardsPoolPendingRetryRecomputesLateEarnings(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		enrollment := f.enroll(t, "session", "owner", 70)
		f.earning(t, "session", "owner", 8, f.optIn.Add(time.Hour))
		pending := f.settle(t, enrollment.MachineID, enrollment.NextDay)
		if pending.Status != earningsfloor.PoolExhausted || pending.DueMicroUSD != 3 || pending.AmountMicroUSD != 0 {
			t.Fatalf("zero-funded pool = %+v", pending)
		}
		rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), "", 100)
		if err != nil || len(rows) != 1 || !rows[0].NextDay.Equal(enrollment.NextDay) {
			t.Fatalf("pending receipt advanced cursor: %+v, %v", rows, err)
		}
		if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), enrollment.MachineID, enrollment.NextDay.AddDate(0, 0, 1)); !errors.Is(err, earningsfloor.ErrDayOrder) {
			t.Fatalf("skipped pending day: %v", err)
		}
		f.fund(t, 2)
		if short := f.settle(t, enrollment.MachineID, enrollment.NextDay); short.Status != earningsfloor.PoolExhausted || short.AmountMicroUSD != 0 {
			t.Fatalf("partially paid floor: %+v", short)
		}
		f.earning(t, "session", "owner", 2, f.optIn.Add(2*time.Hour))
		paid := f.settle(t, enrollment.MachineID, enrollment.NextDay)
		if paid.Status != earningsfloor.Paid || paid.DueMicroUSD != 1 || paid.AmountMicroUSD != 1 || paid.InferenceMicroUSD != 10 || !paid.CreatedAt.Equal(pending.CreatedAt) {
			t.Fatalf("late earning/refill did not re-evaluate pending receipt: %+v", paid)
		}
		f.earning(t, "session", "owner", 9, f.optIn.Add(3*time.Hour))
		if replay := f.settle(t, enrollment.MachineID, enrollment.NextDay); replay != paid {
			t.Fatalf("final receipt changed on late earning: %+v -> %+v", paid, replay)
		}
		for _, invalid := range []int64{-1, 0} {
			if _, err := f.rewards.SetAutopilotRewardPoolCap(t.Context(), invalid); !errors.Is(err, earningsfloor.ErrPoolCap) {
				t.Fatalf("accepted cap %d below spending: %v", invalid, err)
			}
		}
		before, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		f.clock.Store(f.optIn.AddDate(0, 2, 0).UnixMicro())
		after, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || after != before || after.CapMicroUSD != 2 || after.SpentMicroUSD != 1 {
			t.Fatalf("pool reset or automatic funding: %+v -> %+v, %v", before, after, err)
		}
		if balance, withdrawable := f.backend.GetBalanceWithWithdrawable("owner"); balance != 1 || withdrawable != 1 || len(f.backend.LedgerHistory("owner")) != 1 {
			t.Fatalf("retry credited more than once: %d/%d", balance, withdrawable)
		}
	})
}

func TestAutopilotRewardsZeroBaselineAndClosedDayOrder(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		enrollment := f.enroll(t, "session", "owner", 0)
		for _, invalid := range []time.Time{time.Time{}, f.optIn, enrollment.NextDay.AddDate(0, 0, -1), enrollment.NextDay.AddDate(0, 0, 1)} {
			if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), enrollment.MachineID, invalid); err == nil {
				t.Fatalf("accepted invalid/out-of-order day %v", invalid)
			}
		}
		f.clock.Store(f.optIn.UnixMicro())
		if _, err := f.rewards.SettleAutopilotRewardDay(t.Context(), enrollment.MachineID, enrollment.NextDay); err == nil {
			t.Fatal("open UTC day settled")
		}
		f.clock.Store(enrollment.NextDay.AddDate(0, 0, 1).UnixMicro())
		zero := f.settle(t, enrollment.MachineID, enrollment.NextDay)
		if zero.Status != earningsfloor.Zero || zero.FloorMicroUSD != 0 || zero.AmountMicroUSD != 0 {
			t.Fatalf("zero baseline was not finalized: %+v", zero)
		}
		if replay := f.settle(t, enrollment.MachineID, enrollment.NextDay); replay != zero {
			t.Fatalf("zero receipt replay = %+v, want %+v", replay, zero)
		}
		if len(f.backend.LedgerHistory("owner")) != 0 || f.backend.GetWithdrawableBalance("owner") != 0 {
			t.Fatal("zero floor generated money")
		}
		rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), "", 100)
		if err != nil || len(rows) != 1 || !rows[0].BaselineKnown || !rows[0].NextDay.Equal(enrollment.NextDay.AddDate(0, 0, 1)) {
			t.Fatalf("zero floor enrollment/cursor = %+v, %v", rows, err)
		}
	})
}

func TestAutopilotRewardsDoNotChangeOrdinaryBaseRewards(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		enrollment := f.enroll(t, "session", "owner", 70)
		f.fund(t, 11)
		draw := store.ProviderFloorDraw{ProviderKey: "session-key", AccountID: "owner", EpochID: f.optIn.Format("2006-01"), AmountMicroUSD: 500, FloorMicroUSD: 500, CreatedAt: f.optIn.Add(time.Hour)}
		if !settleFloorDraw(t, f.backend, &draw) {
			t.Fatal("ordinary base reward failed")
		}
		before, err := f.backend.ListFloorDrawsForEpoch(t.Context(), draw.EpochID)
		if err != nil {
			t.Fatal(err)
		}
		pool, err := f.rewards.AutopilotRewardPool(t.Context())
		if err != nil || pool.SpentMicroUSD != 0 {
			t.Fatalf("ordinary reward spent Autopilot pool: %+v, %v", pool, err)
		}
		receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay)
		if receipt.AmountMicroUSD != 11 || receipt.InferenceMicroUSD != 0 {
			t.Fatalf("base reward reduced inference shortfall: %+v", receipt)
		}
		after, err := f.backend.ListFloorDrawsForEpoch(t.Context(), draw.EpochID)
		if err != nil || !reflect.DeepEqual(before, after) || settleFloorDraw(t, f.backend, &draw) {
			t.Fatalf("ordinary floor changed after Autopilot settlement: %+v -> %+v, %v", before, after, err)
		}
		if sum, err := f.backend.SumFloorDrawsForEpoch(t.Context(), draw.EpochID); err != nil || sum != 500 {
			t.Fatalf("ordinary budget sum = %d, %v", sum, err)
		}
		if balance, withdrawable := f.backend.GetBalanceWithWithdrawable("owner"); balance != 511 || withdrawable != 511 {
			t.Fatalf("independent rewards = %d/%d, want 511/511", balance, withdrawable)
		}
	})
}

func TestAutopilotRewardsSponsoredInferenceCountsInBaselineAndActual(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		f.observe(t, store.MachineObservation{SessionID: "session", AccountID: "provider", SEKey: "se", At: f.start})
		f.consent(t, "session", "provider", false, f.start)
		if err := f.backend.CreateUser(&store.User{AccountID: "consumer", PrivyUserID: "did:privy:consumer"}); err != nil {
			t.Fatal(err)
		}
		promotions, ok := store.As[store.ModelTokenPromotionStore](f.backend)
		if !ok {
			t.Fatal("missing model token promotion capability")
		}
		now := time.UnixMicro(f.clock.Load()).UTC()
		if err := promotions.PutModelTokenPromotion(store.ModelTokenPromotion{ModelID: "not-registered/model", Tokens: 100, ClaimStartsAt: now.Add(-time.Hour), SignupCutoffAt: now.Add(time.Hour), MaxClaims: 1, Enabled: true}); err != nil {
			t.Fatal(err)
		}
		if _, err := promotions.ClaimModelTokenPromotion("consumer", "not-registered/model", now); err != nil {
			t.Fatal(err)
		}
		pay := func(id string, amount int64, at time.Time) {
			t.Helper()
			reservation, err := promotions.ReserveModelTokens(id, "consumer", "not-registered/model", amount, tokenPrice(amount))
			if err != nil {
				t.Fatal(err)
			}
			result, err := promotions.SettleModelTokenReservation(reservation.ID, amount, tokenPrice(amount), &store.ModelTokenEarning{ProviderEarning: store.ProviderEarning{
				AccountID: "provider", ProviderID: "session", ProviderKey: "session-key", JobID: id,
				Model: reservation.ModelID, AmountMicroUSD: amount, CreatedAt: at,
			}}, true)
			if err != nil || !result.Applied || result.Reservation.ConsumerCostMicroUSD != 0 || result.Reservation.SponsoredMicroUSD != amount {
				t.Fatalf("sponsored payout = %+v, %v", result, err)
			}
		}
		pay("baseline-promo", 70, f.optIn.Add(-48*time.Hour))
		enrollment := f.consent(t, "session", "provider", true, f.optIn)
		pay("daily-promo", 8, f.optIn.Add(time.Hour))
		f.fund(t, 3)
		receipt := f.settle(t, enrollment.MachineID, enrollment.NextDay)
		if enrollment.SevenDayEarningsMicroUSD != 70 || receipt.FloorMicroUSD != 11 || receipt.InferenceMicroUSD != 8 || receipt.AmountMicroUSD != 3 {
			t.Fatalf("sponsored inference excluded: %+v %+v", enrollment, receipt)
		}
		if f.backend.GetBalance("consumer") != 0 || f.backend.GetWithdrawableBalance("provider") != 81 {
			t.Fatal("sponsored/free billing or reward payout changed")
		}
	})
}

func TestAutopilotRewardsEnrollmentPaginationKeepsInactiveAndUnknown(t *testing.T) {
	autopilotRewardsBackends(t, func(t *testing.T, f *autopilotRewardsFixture) {
		var want []string
		for _, session := range []string{"first", "second", "third", "fourth", "inactive"} {
			enrollment := f.enroll(t, session, "owner", 0)
			want = append(want, enrollment.MachineID)
		}
		f.consent(t, "inactive", "owner", false, f.optIn.Add(time.Hour))
		legacy := f.observe(t, store.MachineObservation{SessionID: "legacy", AccountID: "owner", SEKey: "legacy", At: f.start.Add(-48 * time.Hour)})
		if unknown := f.consent(t, "legacy", "owner", true, f.optIn); unknown.BaselineKnown {
			t.Fatal("legacy pagination fixture unexpectedly has a baseline")
		}
		want = append(want, legacy.ID)
		f.observe(t, store.MachineObservation{SessionID: "never-positive", AccountID: "owner", SEKey: "never-positive", At: f.start})
		f.consent(t, "never-positive", "owner", false, f.start)
		slices.Sort(want)
		var got []string
		after := ""
		for {
			rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), after, 2)
			if err != nil || len(rows) > 2 {
				t.Fatalf("bounded page = %+v, %v", rows, err)
			}
			if len(rows) == 0 {
				break
			}
			for _, row := range rows {
				if row.MachineID <= after {
					t.Fatalf("page cursor repeated or regressed: %q -> %q", after, row.MachineID)
				}
				got = append(got, row.MachineID)
				after = row.MachineID
			}
		}
		if !slices.Equal(got, want) {
			t.Fatalf("pagination excluded inactive/unknown or included negative-only consent: %v, want %v", got, want)
		}
		for _, limit := range []int{0, -1, 1000} {
			rows, err := f.rewards.AutopilotRewardEnrollments(t.Context(), "", limit)
			if err != nil || len(rows) != len(want) {
				t.Fatalf("default/clamped page limit%d = %+v, %v", limit, rows, err)
			}
		}
	})
}
