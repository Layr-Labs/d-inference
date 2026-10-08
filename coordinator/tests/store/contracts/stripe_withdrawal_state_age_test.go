package store_test

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStripeWithdrawalStuckSelectionUsesStateAgeBeforeLimit(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			now := time.Now().Truncate(time.Microsecond)
			for _, status := range []string{"pending", "transferred"} {
				for i := range 4 {
					seedStripeWithdrawalState(t, s, fmt.Sprintf("fresh-%s-%d", status, i), status, now.Add(-90*24*time.Hour), now, now)
				}
				seedStripeWithdrawalState(t, s, "stale-older-"+status, status, now.Add(-4*24*time.Hour), now.Add(-80*time.Hour), now.Add(-80*time.Hour))
				seedStripeWithdrawalState(t, s, "stale-newer-"+status, status, now.Add(-5*24*time.Hour), now.Add(-60*time.Hour), now.Add(-60*time.Hour))
				rows, err := s.ListStripeWithdrawalsByStatus(status, now.Add(-48*time.Hour), 2)
				if err != nil || len(rows) != 2 || rows[0].ID != "stale-older-"+status || rows[1].ID != "stale-newer-"+status {
					t.Fatalf("%s: queue age hid genuine stale rows or changed state-age order: %+v, %v", status, rows, err)
				}
			}
			// Old pending rows predate dispatch timestamps. Their creation age
			// must still expose them for manual reconciliation.
			seedStripeWithdrawalState(t, s, "legacy-pending", "pending", now.Add(-100*time.Hour), now, time.Time{})
			rows, err := s.ListStripeWithdrawalsByStatus("pending", now.Add(-48*time.Hour), 1)
			if err != nil || len(rows) != 1 || rows[0].ID != "legacy-pending" {
				t.Fatalf("historical pending age lost its fallback: %+v, %v", rows, err)
			}
		})
	}
}

func TestStripeWithdrawalSweepSelectionOrdersStateAgeBeforeCap(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			now := time.Now().Truncate(time.Microsecond)
			for i := range store.MaxStripeWithdrawalsByStatusLimit {
				seedStripeWithdrawalState(t, s, fmt.Sprintf("unsettled-%04d", i), "transferred", now.Add(-90*24*time.Hour), now, now)
			}
			seedStripeWithdrawalState(t, s, "settled", "transferred", now.Add(-3*24*time.Hour), now.Add(-48*time.Hour), now.Add(-48*time.Hour))
			rows, err := s.ListStripeWithdrawalsForStripeAccount("acct_state_age", "transferred")
			firstID := ""
			if len(rows) > 0 {
				firstID = rows[0].ID
			}
			if err != nil || len(rows) != store.MaxStripeWithdrawalsByStatusLimit || rows[0].ID != "settled" {
				t.Fatalf("freshly transferred old queue hid settled row beyond cap: first=%s count=%d, %v", firstID, len(rows), err)
			}
			if rows[1].ID != "unsettled-0000" || rows[2].ID != "unsettled-0001" {
				t.Fatalf("equal state ages have unstable order: %s, %s", rows[1].ID, rows[2].ID)
			}
		})
	}
}

func seedStripeWithdrawalState(t *testing.T, s store.Store, id, status string, created, updated, started time.Time) {
	t.Helper()
	w := &store.StripeWithdrawal{
		ID: id, AccountID: "state-age-account", StripeAccountID: "acct_state_age", AmountMicroUSD: 1_000_000,
		NetMicroUSD: 1_000_000, Method: "standard", Status: status, CreatedAt: created, UpdatedAt: updated, TransferStartedAt: started,
	}
	if status == "transferred" {
		w.TransferID = "tr_" + id
	}
	seedStripeWithdrawal(t, s, w)
}
