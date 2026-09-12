package store

import (
	"reflect"
	"testing"
)

func TestStripePayoutFailureChecksCurrentOwnership(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			if err := s.CreateUser(&User{AccountID: "acct-sweep-guard", PrivyUserID: "did:privy:sweep-guard"}); err != nil {
				t.Fatal(err)
			}
			for _, tc := range []struct {
				id, status, payout string
				refunded, applied  bool
			}{
				{"matching", "paid", "matching", false, true},
				{"pending", "pending", "matching", false, true},
				{"transferred", "transferred", "matching", false, true},
				{"new-sweep", "paid", "different", false, false},
				{"reopened", "transferred", "", false, false},
				{"refunded", "paid", "matching", true, false},
				{"failed", "failed", "matching", false, false},
			} {
				t.Run(tc.id, func(t *testing.T) {
					wd := &StripeWithdrawal{ID: tc.id, AccountID: "acct-sweep-guard", StripeAccountID: "acct_stripe_guard",
						AmountMicroUSD: 5_000_000, NetMicroUSD: 4_500_000, FeeMicroUSD: 500_000,
						Method: "instant", Status: tc.status, TransferID: "tr_" + tc.id,
						PayoutID: tc.payout, Refunded: tc.refunded, FeeRefunded: false}
					if wd.PayoutID != "" {
						wd.PayoutID += "_" + tc.id
					}
					if tc.id == "reopened" {
						wd.Status = "paid"
						wd.SweepPayoutID = "po_new_sweep"
					}
					if err := s.CreateStripeWithdrawal(wd); err != nil {
						t.Fatal(err)
					}
					before, err := s.GetStripeWithdrawal(wd.ID)
					if err != nil {
						t.Fatal(err)
					}
					applied, err := s.ReopenStripeWithdrawalAfterPayoutFailure(wd.ID, "matching_"+tc.id, "payout bounced", true)
					if err != nil || applied != tc.applied {
						t.Fatalf("applied=%v want=%v err=%v", applied, tc.applied, err)
					}
					got, err := s.GetStripeWithdrawal(wd.ID)
					if err != nil {
						t.Fatal(err)
					}
					if applied {
						before.Status, before.PayoutID, before.FailureReason = "transferred", "", "payout bounced"
						before.FeeRefunded = true
						if got.UpdatedAt.Before(before.UpdatedAt) {
							t.Fatal("updated timestamp moved backwards")
						}
						before.UpdatedAt = got.UpdatedAt
					}
					if !reflect.DeepEqual(before, got) {
						t.Fatalf("unexpected state change: expected=%+v actual=%+v", before, got)
					}
					if applied, err := s.ReopenStripeWithdrawalAfterPayoutFailure(wd.ID, "matching_"+tc.id, "redelivery", true); err != nil || applied {
						t.Fatalf("duplicate/stale delivery applied=%v err=%v", applied, err)
					}
					if s.GetBalance(wd.AccountID) != 0 {
						t.Fatal("sweep bounce moved ledger balance")
					}
				})
			}
			for _, ids := range [][2]string{{"", "matching"}, {"matching", ""}} {
				if applied, err := s.ReopenStripeWithdrawalAfterPayoutFailure(ids[0], ids[1], "bounce", true); err == nil || applied {
					t.Fatalf("invalid ids accepted: %v applied=%v err=%v", ids, applied, err)
				}
			}
		})
	}
}
