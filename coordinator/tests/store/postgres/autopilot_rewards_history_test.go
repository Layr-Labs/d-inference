package postgres_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsEarlierIndependentSessionDeclarationIsNeverLost(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	var machineID string
	for _, session := range []string{"a", "b"} {
		identity, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: session, AccountID: "owner", SEKey: "stable", At: f.firstSeen})
		if err != nil {
			t.Fatal(err)
		}
		machineID = identity.ID
	}
	if _, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "a", AccountID: "owner", Supported: true, At: f.firstSeen}); err != nil {
		t.Fatal(err)
	}
	f.earning(t, "owner", "a", "baseline", "inference", 70, first.Add(-24*time.Hour))
	// B's newer false commits first. A's earlier server-received positive must
	// still become durable evidence, without replacing B's current state.
	newerFalse := first.Add(time.Second)
	if empty, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "b", AccountID: "owner", Supported: true, At: newerFalse}); err != nil || empty.MachineID != "" {
		t.Fatalf("newer false created enrollment: %+v %v", empty, err)
	}
	enrollment, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "a", AccountID: "owner", Supported: true, OptedIn: true, At: first})
	if err != nil || enrollment.MachineID != machineID || !enrollment.BaselineKnown || enrollment.HistoryConflict || enrollment.FirstOptInAt == nil || !enrollment.FirstOptInAt.Equal(first) || enrollment.DailyFloorMicroUSD != 11 {
		t.Fatalf("earlier independent positive was dropped or re-anchored: %+v %v", enrollment, err)
	}
	if enrollment.OptedIn || !enrollment.ObservedAt.Equal(newerFalse) {
		t.Fatalf("historical insertion regressed current consent: %+v", enrollment)
	}
	f.reopenRewards(t)
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 || rows[0].FirstOptInAt == nil || !rows[0].FirstOptInAt.Equal(first) || rows[0].OptedIn {
		t.Fatalf("original evidence lost on reopen: %+v %v", rows, err)
	}
}

func TestAutopilotRewardsLateEarlierPositiveFencesFrozenBaseline(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	frozenFirst := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	enrollment := f.enroll(t, "owner", "b", frozenFirst, 70)
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "a", AccountID: "owner", SEKey: "b", At: f.firstSeen.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 100); err != nil {
		t.Fatal(err)
	}
	paid, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, enrollment.NextDay)
	if err != nil || paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 11 {
		t.Fatalf("initial receipt: %+v %v", paid, err)
	}
	const enrollmentRows = `SELECT row_to_json(e)::text FROM autopilot_reward_enrollments e ORDER BY machine_id`
	frozen := queryLines(t, f.pool, enrollmentRows)
	earlier := frozenFirst.Add(-48 * time.Hour)
	conflict, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "a", AccountID: "owner", Supported: true, OptedIn: true, At: earlier})
	if err != nil || !conflict.HistoryConflict || !conflict.BaselineKnown || !conflict.FirstOptInAt.Equal(frozenFirst) || conflict.DailyFloorMicroUSD != 11 {
		t.Fatalf("late evidence silently kept a payable wrong anchor: %+v %v", conflict, err)
	}
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 || !rows[0].HistoryConflict {
		t.Fatalf("history conflict not visible to worker/admin: %+v %v", rows, err)
	}
	if replay, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, enrollment.NextDay); err != nil || replay != paid {
		t.Fatalf("conflict rewrote a final receipt: %+v %v", replay, err)
	}
	pending, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, enrollment.NextDay.Add(24*time.Hour))
	if err != nil || pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 || pending.DueMicroUSD != 0 {
		t.Fatalf("conflicted baseline funded another day: %+v %v", pending, err)
	}
	assertSameLines(t, "frozen promise and cursor", frozen, "after discovered conflict", queryLines(t, f.pool, enrollmentRows))
	pool, err := f.AutopilotRewardPool(ctx)
	if err != nil || pool.SpentMicroUSD != 11 || f.GetBalance("owner") != 11 {
		t.Fatalf("conflict changed cumulative credit: %+v %v", pool, err)
	}
	if _, err := f.RestoreAutopilotBaseline(ctx, earningsfloor.Baseline{MachineID: enrollment.MachineID, FirstOptInAt: earlier, SevenDayEarningsMicroUSD: 0, Evidence: "earlier authenticated session"}); !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
		t.Fatalf("ordinary backfill rewrote a funded promise: %v", err)
	}
	f.reopenRewards(t)
	rows, err = f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 || !rows[0].HistoryConflict || !rows[0].FirstOptInAt.Equal(frozenFirst) {
		t.Fatalf("conflict vanished on reopen: %+v %v", rows, err)
	}
}
