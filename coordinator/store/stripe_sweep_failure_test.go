package store

import (
	"reflect"
	"testing"
)

func TestStripeSweepFailureChecksCurrentOwnership(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			if err := s.CreateUser(&User{AccountID: "acct-sweep-guard", PrivyUserID: "did:privy:sweep-guard"}); err != nil {
				t.Fatal(err)
			}
			for _, tc := range []struct {
				id, status, sweep string
				refunded, applied bool
			}{
				{"matching", "paid", "po_old", false, true},
				{"new-sweep", "paid", "po_new", false, false},
				{"reopened", "transferred", "", false, false},
				{"refunded", "paid", "po_old", true, false},
				{"failed", "failed", "po_old", false, false},
			} {
				t.Run(tc.id, func(t *testing.T) {
					wd := &StripeWithdrawal{ID: tc.id, AccountID: "acct-sweep-guard", StripeAccountID: "acct_stripe_guard",
						AmountMicroUSD: 5_000_000, NetMicroUSD: 4_500_000, FeeMicroUSD: 500_000,
						Method: "instant", Status: tc.status, TransferID: "tr_" + tc.id,
						SweepPayoutID: tc.sweep, Refunded: tc.refunded, FeeRefunded: true}
					if err := s.CreateStripeWithdrawal(wd); err != nil {
						t.Fatal(err)
					}
					before, err := s.GetStripeWithdrawal(wd.ID)
					if err != nil {
						t.Fatal(err)
					}
					applied, err := s.ReopenStripeWithdrawalAfterSweepFailure(wd.ID, "po_old", "sweep bounced")
					if err != nil || applied != tc.applied {
						t.Fatalf("applied=%v want=%v err=%v", applied, tc.applied, err)
					}
					got, err := s.GetStripeWithdrawal(wd.ID)
					if err != nil {
						t.Fatal(err)
					}
					if applied {
						before.Status, before.SweepPayoutID, before.FailureReason = "transferred", "", "sweep bounced"
						if got.UpdatedAt.Before(before.UpdatedAt) {
							t.Fatal("updated timestamp moved backwards")
						}
						before.UpdatedAt = got.UpdatedAt
					}
					if !reflect.DeepEqual(before, got) {
						t.Fatalf("unexpected state change: expected=%+v actual=%+v", before, got)
					}
					if applied, err := s.ReopenStripeWithdrawalAfterSweepFailure(wd.ID, "po_old", "redelivery"); err != nil || applied {
						t.Fatalf("duplicate/stale delivery applied=%v err=%v", applied, err)
					}
					if s.GetBalance(wd.AccountID) != 0 {
						t.Fatal("sweep bounce moved ledger balance")
					}
				})
			}
			if applied, err := s.ReopenStripeWithdrawalAfterSweepFailure("missing", "po_old", "bounce"); err != nil || applied {
				t.Fatalf("missing row applied=%v err=%v", applied, err)
			}
			for _, ids := range [][2]string{{"", "po_old"}, {"matching", ""}} {
				if applied, err := s.ReopenStripeWithdrawalAfterSweepFailure(ids[0], ids[1], "bounce"); err == nil || applied {
					t.Fatalf("invalid ids accepted: %v applied=%v err=%v", ids, applied, err)
				}
			}
		})
	}
}
