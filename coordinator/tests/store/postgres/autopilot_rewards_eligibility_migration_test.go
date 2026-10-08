package postgres_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

func TestAutopilotRewardsEligibilityMigrationPreservesMoneyAndConsent(t *testing.T) {
	f := newAutopilotRewardsFixture(t)
	ctx := t.Context()
	first := f.firstSeen.Add(8*24*time.Hour + 12*time.Hour)
	e := f.enroll(t, "owner", "legacy", first, 70)
	if _, err := f.SetAutopilotRewardPoolCap(ctx, 100); err != nil {
		t.Fatal(err)
	}
	paid, err := f.SettleAutopilotRewardDay(ctx, e.MachineID, e.NextDay)
	if err != nil || paid.Status != earningsfloor.Paid || paid.AmountMicroUSD != 11 {
		t.Fatalf("preupgrade payment: %+v %v", paid, err)
	}
	// Simulate the consent shape left by migration31, retaining financial rows.
	// Later versions are unrecorded too: goose refuses a gap below the highest
	// applied version, and they rerun without changing the reward tables.
	if _, err := f.pool.Exec(ctx, `ALTER TABLE autopilot_reward_consents DROP COLUMN qualified, DROP COLUMN chip, DROP COLUMN memory_gb;
	 DELETE FROM goose_db_version WHERE version_id>=32`); err != nil {
		t.Fatal(err)
	}
	f.reopenRewards(t)
	var optedIn, qualified bool
	if err := f.pool.QueryRow(ctx, `SELECT opted_in,qualified FROM autopilot_reward_consents WHERE session_id='legacy' AND opted_in`).Scan(&optedIn, &qualified); err != nil || !optedIn || qualified {
		t.Fatalf("upgrade invented evidence or erased saved consent: %v/%v %v", optedIn, qualified, err)
	}
	rows, err := f.AutopilotRewardEnrollments(ctx, "", 10)
	if err != nil || len(rows) != 1 || !rows[0].BaselineKnown || !rows[0].FirstOptInAt.Equal(first) || rows[0].SevenDayEarningsMicroUSD != 70 || rows[0].DailyFloorMicroUSD != 11 {
		t.Fatalf("upgrade changed frozen baseline: %+v %v", rows, err)
	}
	replay, err := f.SettleAutopilotRewardDay(ctx, e.MachineID, e.NextDay)
	if err != nil || replay != paid {
		t.Fatalf("upgrade changed finalized payment: %+v %v", replay, err)
	}
	next, err := f.SettleAutopilotRewardDay(ctx, e.MachineID, e.NextDay.AddDate(0, 0, 1))
	if err != nil || next.Status != earningsfloor.Ineligible || next.AmountMicroUSD != 0 {
		t.Fatalf("legacy consent invented daily qualification: %+v %v", next, err)
	}
	pool, err := f.AutopilotRewardPool(ctx)
	if err != nil || pool.CapMicroUSD != 100 || pool.SpentMicroUSD != 11 || f.GetBalance("owner") != 11 || f.GetWithdrawableBalance("owner") != 11 {
		t.Fatalf("upgrade or replay changed money: %+v %v", pool, err)
	}
}
