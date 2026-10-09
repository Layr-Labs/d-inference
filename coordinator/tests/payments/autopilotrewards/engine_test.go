package autopilotrewards_test

import (
	"context"
	"log/slog"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/floorpolicy"
	"github.com/eigeninference/d-inference/coordinator/payments/autopilotrewards"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAutopilotDailyFloorRoundsOnceWithoutOverflow(t *testing.T) {
	for _, tc := range []struct{ weekly, want int64 }{
		{0, 0}, {6, 0}, {7, 1}, {13, 2}, {70_000_000, 11_000_000},
		{math.MaxInt64, math.MaxInt64/70*11 + math.MaxInt64%70*11/70},
	} {
		got, err := floorpolicy.DailyFloor(tc.weekly)
		if err != nil || got != tc.want {
			t.Fatalf("DailyFloor(%d)=%d,%v want %d", tc.weekly, got, err, tc.want)
		}
	}
	if _, err := floorpolicy.DailyFloor(-1); err == nil {
		t.Fatal("negative baseline accepted")
	}
}

func TestAutopilotRewardDayUsesUTCAndRejectsOpenDays(t *testing.T) {
	now := time.Date(2026, 10, 12, 0, 0, 0, 0, time.UTC)
	day := now.AddDate(0, 0, -1)
	if err := floorpolicy.ValidateDay(day.In(time.FixedZone("west", -7*3600)), now); err != nil {
		t.Fatal(err)
	}
	for _, invalid := range []time.Time{time.Time{}, now, now.AddDate(0, 0, 1), day.Add(time.Nanosecond)} {
		if err := floorpolicy.ValidateDay(invalid, now); err == nil {
			t.Fatalf("non-closed UTC day accepted: %s", invalid)
		}
	}
	if got := floorpolicy.Day(now.In(time.FixedZone("west", -7*3600))); !got.Equal(now) {
		t.Fatalf("used local calendar: %s", got)
	}
}

func TestAutopilotRewardCutoffIncludesNovember7Only(t *testing.T) {
	end := time.Date(2026, time.November, 8, 0, 0, 0, 0, time.UTC)
	lastDay := end.AddDate(0, 0, -1)
	if err := floorpolicy.ValidateDay(lastDay, end); err != nil {
		t.Fatalf("November 7 must settle at midnight November 8: %v", err)
	}
	if err := floorpolicy.ValidateDay(lastDay, end.AddDate(0, 0, 20)); err != nil {
		t.Fatalf("late settlement of an eligible day must remain allowed: %v", err)
	}
	for _, day := range []time.Time{end, end.AddDate(0, 0, 1), end.In(time.FixedZone("west", -7*3600))} {
		if err := floorpolicy.ValidateDay(day, end.AddDate(0, 0, 20)); err == nil {
			t.Fatalf("expired UTC day accepted: %s", day)
		}
	}
}

func TestAutopilotRewardWorkerUsesSharedEndForLateEnrollment(t *testing.T) {
	st, engine, _, now := rewardWorkerFixture(t, true)
	end := time.Date(2026, time.November, 8, 0, 0, 0, 0, time.UTC)
	*now = end.Add(-12 * time.Hour)
	late, err := st.ObserveMachine(t.Context(), store.MachineObservation{
		SessionID: "late-session", AccountID: "late-owner", SEKey: "late-key",
		At: now.AddDate(0, 0, -10), Source: "live_registration",
	})
	if err != nil {
		t.Fatal(err)
	}
	savedNow := *now
	*now = floorpolicy.Day(*now)
	if err := st.OpenProviderSession(t.Context(), "late-session", "", "late-owner"); err != nil {
		t.Fatal(err)
	}
	*now = savedNow
	if err := st.TouchProviderSession(t.Context(), "late-session", "", "late-owner", "late-key", end); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveAutopilotConsent(t.Context(), earningsfloor.Consent{
		SessionID: "late-session", AccountID: "late-owner", Supported: true, Qualified: true, OptedIn: true, At: *now,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.RestoreAutopilotBaseline(t.Context(), earningsfloor.Baseline{
		MachineID: late.ID, FirstOptInAt: *now, SevenDayEarningsMicroUSD: 70_000_000, Evidence: "verified late enrollment history",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SetAutopilotRewardPoolCap(t.Context(), 1_000_000_000); err != nil {
		t.Fatal(err)
	}
	*now = end.Add(-time.Nanosecond)
	before, err := engine.SettleClosedDays(t.Context())
	if err != nil || before.ProcessedDays != 29 || st.GetBalance("late-owner") != 0 {
		t.Fatalf("an open November 7 was settled: %+v %v", before, err)
	}
	*now = end
	last, err := engine.SettleClosedDays(t.Context())
	if err != nil || last.ProcessedDays != 2 || last.More || st.GetBalance("worker-account") != 330_000_000 || st.GetBalance("late-owner") != 11_000_000 {
		t.Fatalf("early and late enrollees did not share final day: %+v %v", last, err)
	}
	*now = end.AddDate(0, 0, 20)
	after, err := engine.SettleClosedDays(t.Context())
	if err != nil || after.ProcessedDays != 0 || after.More || after.PoolPending != 0 || after.HistoryPending != 0 {
		t.Fatalf("worker continued beyond shared end: %+v %v", after, err)
	}
	pool, err := st.AutopilotRewardPool(t.Context())
	if err != nil || pool.SpentMicroUSD != 341_000_000 {
		t.Fatalf("post-cutoff money changed: %+v %v", pool, err)
	}
}

func rewardWorkerFixture(t *testing.T, restore bool) (*memory.MemoryStore, *autopilotrewards.Engine, string, *time.Time) {
	t.Helper()
	now := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	clock := func() time.Time { return now }
	st := memory.NewMemory(store.Config{Now: clock})
	machine, err := st.ObserveMachine(context.Background(), store.MachineObservation{
		SessionID: "worker-session", AccountID: "worker-account", SEKey: "worker-key",
		At: now.AddDate(0, 0, -10), Source: "live_registration",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.OpenProviderSession(t.Context(), "worker-session", "", "worker-account"); err != nil {
		t.Fatal(err)
	}
	if err := st.TouchProviderSession(t.Context(), "worker-session", "", "worker-account", "worker-key", time.Date(2026, 11, 8, 0, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	now = now.AddDate(0, 0, 8)
	if _, err := st.ObserveAutopilotConsent(context.Background(), earningsfloor.Consent{
		SessionID: "worker-session", AccountID: "worker-account", Supported: true, Qualified: true, OptedIn: true, At: now,
	}); err != nil {
		t.Fatal(err)
	}
	if restore {
		if _, err := st.RestoreAutopilotBaseline(context.Background(), earningsfloor.Baseline{
			MachineID: machine.ID, FirstOptInAt: now.AddDate(0, 0, -1),
			SevenDayEarningsMicroUSD: 70_000_000, Evidence: "verified first enrollment and complete seven-day inference archive",
		}); err != nil {
			t.Fatal(err)
		}
	}
	return st, autopilotrewards.NewEngine(st, slog.New(slog.DiscardHandler), clock), machine.ID, &now
}

func TestAutopilotRewardWorkerCatchesUpIndependentUTCDaysAfterPoolFunding(t *testing.T) {
	st, engine, _, now := rewardWorkerFixture(t, true)
	start := *now
	*now = now.AddDate(0, 0, 3)
	for i, amount := range []int64{8_000_000, 10_000_000, 12_000_000} {
		if err := st.RecordProviderEarning(&store.ProviderEarning{
			AccountID: "worker-account", ProviderID: "worker-session", ProviderKey: "worker-key",
			JobID: start.AddDate(0, 0, i).Format("2006-01-02"), Model: "inference-model",
			AmountMicroUSD: amount, CreatedAt: start.AddDate(0, 0, i).Add(time.Hour),
		}); err != nil {
			t.Fatal(err)
		}
	}
	result, err := engine.SettleClosedDays(context.Background())
	if err != nil || result.PoolPending != 1 || result.ProcessedDays != 0 || st.GetBalance("worker-account") != 0 {
		t.Fatalf("unfunded worker: %+v %v", result, err)
	}
	if _, err := st.SetAutopilotRewardPoolCap(context.Background(), 4_000_000); err != nil {
		t.Fatal(err)
	}
	result, err = engine.SettleClosedDays(context.Background())
	if err != nil || result.ProcessedDays != 3 || result.PoolPending != 0 || result.More {
		t.Fatalf("funded catch-up: %+v %v", result, err)
	}
	pool, err := st.AutopilotRewardPool(context.Background())
	if err != nil || pool.SpentMicroUSD != 4_000_000 || st.GetBalance("worker-account") != 4_000_000 || st.GetWithdrawableBalance("worker-account") != 4_000_000 {
		t.Fatalf("daily shortfalls not paid once: pool=%+v error=%v", pool, err)
	}
	result, err = engine.SettleClosedDays(context.Background())
	if err != nil || result.ProcessedDays != 0 || st.GetBalance("worker-account") != 4_000_000 {
		t.Fatalf("restart/replay credited again: %+v %v", result, err)
	}
}

func TestAutopilotRewardWorkerDoesNotGuessHistoricalFirstOptIn(t *testing.T) {
	st, engine, machineID, now := rewardWorkerFixture(t, false)
	*now = now.AddDate(0, 0, 1)
	if _, err := st.SetAutopilotRewardPoolCap(context.Background(), 100_000_000); err != nil {
		t.Fatal(err)
	}
	result, err := engine.SettleClosedDays(context.Background())
	if err != nil || result.HistoryPending != 1 || result.ProcessedDays != 0 || st.GetBalance("worker-account") != 0 {
		t.Fatalf("unknown history got paid: %+v %v", result, err)
	}
	enrollments, err := st.AutopilotRewardEnrollments(context.Background(), "", 100)
	if err != nil || len(enrollments) != 1 || enrollments[0].MachineID != machineID || enrollments[0].FirstOptInAt != nil || enrollments[0].BaselineKnown {
		t.Fatalf("history was reanchored: %+v %v", enrollments, err)
	}
}

func TestAutopilotRewardWorkerRunStopsOnCancellation(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	done := make(chan struct{})
	go func() {
		autopilotrewards.NewEngine(st, slog.New(slog.DiscardHandler), nil).Run(ctx)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("reward worker ignored shutdown")
	}
}

func TestAutopilotRewardWorkerWithholdsConflictedFrozenHistory(t *testing.T) {
	st, engine, machineID, now := rewardWorkerFixture(t, true)
	*now = now.AddDate(0, 0, 1)
	if _, err := st.ObserveMachine(context.Background(), store.MachineObservation{
		SessionID: "earlier-session", AccountID: "worker-account", SEKey: "worker-key",
		At: now.AddDate(0, 0, -20), Source: "live_registration",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ObserveAutopilotConsent(context.Background(), earningsfloor.Consent{
		SessionID: "earlier-session", AccountID: "worker-account", Supported: true, Qualified: true, OptedIn: true, At: now.AddDate(0, 0, -3),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.SetAutopilotRewardPoolCap(context.Background(), 100_000_000); err != nil {
		t.Fatal(err)
	}
	result, err := engine.SettleClosedDays(context.Background())
	if err != nil || result.HistoryPending != 1 || result.ProcessedDays != 0 || st.GetBalance("worker-account") != 0 {
		t.Fatalf("conflicting earlier declaration ignored: %+v %v", result, err)
	}
	enrollments, err := st.AutopilotRewardEnrollments(context.Background(), "", 100)
	if err != nil || len(enrollments) != 1 || enrollments[0].MachineID != machineID || !enrollments[0].BaselineKnown || !enrollments[0].HistoryConflict || enrollments[0].SevenDayEarningsMicroUSD != 70_000_000 {
		t.Fatalf("frozen snapshot was silently changed: %+v %v", enrollments, err)
	}
}
