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
	now = now.AddDate(0, 0, 8)
	if _, err := st.ObserveAutopilotConsent(context.Background(), earningsfloor.Consent{
		SessionID: "worker-session", AccountID: "worker-account", Supported: true, OptedIn: true, At: now,
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
		SessionID: "earlier-session", AccountID: "worker-account", Supported: true, OptedIn: true, At: now.AddDate(0, 0, -3),
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
