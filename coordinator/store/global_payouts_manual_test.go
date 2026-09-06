package store

import (
	"testing"
	"time"
)

func TestGlobalPayoutManualReviewDoesNotCrowdReconciliation(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := As[GlobalPayoutStore](s)
			now := time.Now()
			old := payoutFixture(t, s, g, "gp-manual", "gp-manual-old")
			if _, err := g.BeginGlobalPayout(old.AccountID, old.ID, now.Add(-13*time.Hour)); err != nil {
				t.Fatal(err)
			}
			if claimed, err := g.ClaimGlobalPayout(old.ID, now); err != nil || !claimed {
				t.Fatalf("initial claim: %v %v", claimed, err)
			}
			if err := g.ApplyGlobalPayout(old.ID, GlobalPayoutResult{FailureCode: GlobalPayoutManualReview}, now); err != nil {
				t.Fatal(err)
			}
			active := payoutFixture(t, s, g, "gp-active", "gp-manual-active")
			if _, err := g.BeginGlobalPayout(active.AccountID, active.ID, now); err != nil {
				t.Fatal(err)
			}
			for _, later := range []time.Time{now.Add(2 * time.Minute), now.Add(24 * time.Hour)} {
				rows, err := g.ListGlobalPayoutsToReconcile(later, 1)
				if err != nil || len(rows) != 1 || rows[0].ID != active.ID {
					t.Fatalf("manual row crowded active payout out of batch: %+v %v", rows, err)
				}
				if claimed, err := g.ClaimGlobalPayout(old.ID, later); err != nil || claimed {
					t.Fatalf("manual payout claimed again: %v %v", claimed, err)
				}
			}
			parked, _ := g.GetGlobalPayout(old.ID)
			if parked.DispatchAttempts != 1 || parked.Refunded || !parked.CheckedAt.Equal(now) || s.GetWithdrawableBalance(old.AccountID) != 2_000_000 {
				t.Fatalf("manual payout mutated or refunded: %+v", parked)
			}
			// An operator-verified remote identity can resume readback without
			// permitting any new send or debit for the parked withdrawal.
			if err := g.ApplyGlobalPayout(old.ID, GlobalPayoutResult{ExternalID: "obp_found", Status: "processing"}, now); err != nil {
				t.Fatal(err)
			}
			if claimed, err := g.ClaimGlobalPayout(old.ID, now.Add(2*time.Minute)); err != nil || !claimed {
				t.Fatalf("known remote payout could not resume: %v %v", claimed, err)
			}
			resumed, _ := g.GetGlobalPayout(old.ID)
			if resumed.DispatchAttempts != 1 || resumed.ExternalID != "obp_found" {
				t.Fatalf("remote reconciliation created a dispatch: %+v", resumed)
			}
		})
	}
}
