package postgres_test

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsTrackedBaselineRechecksLateUnsupportedBinding(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	if _, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "old-client", AccountID: "owner", At: first.Add(-time.Hour)}); !errors.Is(err, earningsfloor.ErrIdentity) {
		t.Fatalf("journal unbound unsupported declaration: %v", err)
	}
	enrollment := f.enroll(t, "owner", "a", first, 70)
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 100); err != nil {
		t.Fatal(err)
	}
	paid, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, enrollment.NextDay)
	if err != nil || paid.AmountMicroUSD != 11 {
		t.Fatalf("initial tracked payment: %+v %v", paid, err)
	}
	const enrollmentRows = `SELECT row_to_json(e)::text FROM autopilot_reward_enrollments e ORDER BY machine_id`
	frozen := queryLines(t, f.pool, enrollmentRows)
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "old-client", AccountID: "owner", SEKey: "a", At: first.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 || !rows[0].HistoryConflict {
		t.Fatalf("late unsupported binding left an unproven automatic baseline payable: %+v %v", rows, err)
	}
	if !rows[0].BaselineKnown || rows[0].BaselineSource != earningsfloor.TrackedBaseline || !rows[0].FirstOptInAt.Equal(first) || rows[0].DailyFloorMicroUSD != 11 {
		t.Fatalf("history recheck rewrote frozen baseline/provenance: %+v", rows[0])
	}
	if replay, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, enrollment.NextDay); err != nil || replay != paid {
		t.Fatalf("history recheck rewrote a final receipt: %+v %v", replay, err)
	}
	pending, err := f.SettleAutopilotRewardDay(ctx, enrollment.MachineID, enrollment.NextDay.Add(24*time.Hour))
	if err != nil || pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 {
		t.Fatalf("incomplete tracked history funded another day: %+v %v", pending, err)
	}
	assertSameLines(t, "frozen baseline and cursor", frozen, "after history recheck", queryLines(t, f.pool, enrollmentRows))
	f.reopenRewards(t)
	rows, err = f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 || !rows[0].HistoryConflict || rows[0].BaselineSource != earningsfloor.TrackedBaseline {
		t.Fatalf("history conflict/provenance lost on reopen: %+v %v", rows, err)
	}
	pool, err := f.AutopilotRewardPool(ctx)
	if err != nil || pool.SpentMicroUSD != 11 || f.GetBalance("owner") != 11 {
		t.Fatalf("history recheck changed credited money: %+v %v", pool, err)
	}
	if _, err := f.RestoreAutopilotBaseline(ctx, earningsfloor.Baseline{MachineID: enrollment.MachineID, FirstOptInAt: first, SevenDayEarningsMicroUSD: 70, Evidence: "replacement evidence"}); !errors.Is(err, earningsfloor.ErrBaselineFrozen) {
		t.Fatalf("ordinary restore changed a frozen source: %v", err)
	}
}

func TestAutopilotRewardsVerifiedSourceOverridesKnownGapsNotPositiveContradictions(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "a", AccountID: "owner", SEKey: "a", At: f.firstSeen.Add(-48 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	unknown, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "a", AccountID: "owner", Supported: true, OptedIn: true, At: first})
	if err != nil || unknown.BaselineKnown || unknown.BaselineSource != "" {
		t.Fatalf("pretracking machine did not require verified history: %+v %v", unknown, err)
	}
	// The free-text evidence deliberately equals the automatic evidence label.
	// Only the explicit source column can authorize the verified-history rule.
	verified, err := f.RestoreAutopilotBaseline(ctx, earningsfloor.Baseline{MachineID: unknown.MachineID, FirstOptInAt: first, SevenDayEarningsMicroUSD: 70, Evidence: "tracked_inference_history"})
	if err != nil || verified.BaselineSource != earningsfloor.VerifiedBaseline || verified.HistoryConflict {
		t.Fatalf("verified baseline source: %+v %v", verified, err)
	}
	if _, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "old-client", AccountID: "owner", At: first.Add(-time.Hour)}); !errors.Is(err, earningsfloor.ErrIdentity) {
		t.Fatal(err)
	}
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "old-client", AccountID: "owner", SEKey: "a", At: first.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	f.reopenRewards(t)
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 100)
	if err != nil || len(rows) != 1 || rows[0].HistoryConflict || rows[0].BaselineSource != earningsfloor.VerifiedBaseline {
		t.Fatalf("known old-client/pretracking gap invalidated verified evidence: %+v %v", rows, err)
	}
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 100); err != nil {
		t.Fatal(err)
	}
	paid, err := f.SettleAutopilotRewardDay(ctx, verified.MachineID, verified.NextDay)
	if err != nil || paid.AmountMicroUSD != 11 {
		t.Fatalf("verified historical baseline withheld: %+v %v", paid, err)
	}
	if _, err := f.ObserveMachine(ctx, store.MachineObservation{SessionID: "earlier-positive", AccountID: "owner", SEKey: "a", At: first.Add(2 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	contradicted, err := f.ObserveAutopilotConsent(ctx, earningsfloor.Consent{SessionID: "earlier-positive", AccountID: "owner", Supported: true, OptedIn: true, At: first.Add(-2 * time.Hour)})
	if err != nil || !contradicted.HistoryConflict || contradicted.BaselineSource != earningsfloor.VerifiedBaseline || !contradicted.FirstOptInAt.Equal(first) {
		t.Fatalf("verified source overrode contradictory positive evidence: %+v %v", contradicted, err)
	}
	pending, err := f.SettleAutopilotRewardDay(ctx, verified.MachineID, verified.NextDay.Add(24*time.Hour))
	if err != nil || pending.Status != earningsfloor.HistoryRequired || pending.AmountMicroUSD != 0 {
		t.Fatalf("contradicted verified promise remained payable: %+v %v", pending, err)
	}
	if replay, err := f.SettleAutopilotRewardDay(ctx, verified.MachineID, verified.NextDay); err != nil || replay != paid {
		t.Fatalf("contradiction changed final receipt: %+v %v", replay, err)
	}
}
