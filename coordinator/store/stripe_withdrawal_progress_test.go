package store

import (
	"fmt"
	"reflect"
	"sync"
	"testing"
)

func TestStripeWithdrawalProgressCompareAndSwap(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			const account = "progress-cas-account"
			if err := s.CreateUser(&User{AccountID: account, PrivyUserID: "did:privy:progress-cas"}); err != nil {
				t.Fatal(err)
			}
			mutations := []func(*StripeWithdrawal){
				func(w *StripeWithdrawal) { w.TransferID = "tr-new" }, func(w *StripeWithdrawal) { w.PayoutID = "po-new" },
				func(w *StripeWithdrawal) { w.SweepPayoutID = "sweep-new" }, func(w *StripeWithdrawal) { w.Status = "paid" },
				func(w *StripeWithdrawal) { w.FailureReason = "new reason" }, func(w *StripeWithdrawal) { w.Refunded = true }, func(w *StripeWithdrawal) { w.FeeRefunded = true },
			}
			for i, change := range mutations {
				t.Run(fmt.Sprint(i), func(t *testing.T) {
					row := &StripeWithdrawal{ID: fmt.Sprintf("progress-cas-%d", i), AccountID: account, StripeAccountID: "acct_progress", AmountMicroUSD: 5_000_000, NetMicroUSD: 4_500_000, FeeMicroUSD: 500_000, Method: "instant", Status: "transferred", TransferID: fmt.Sprintf("tr_old_%d", i), PayoutID: fmt.Sprintf("po_old_%d", i)}
					if err := s.CreateStripeWithdrawal(row); err != nil {
						t.Fatal(err)
					}
					before, err := s.GetStripeWithdrawal(row.ID)
					if err != nil {
						t.Fatal(err)
					}
					next := *before
					change(&next)
					// Immutable field edits are ignored by both implementations.
					next.AccountID = "wrong"
					next.AmountMicroUSD = 1
					next.Method = "wrong"
					if ok, err := s.CompareAndSwapStripeWithdrawal(before, &next); err != nil || !ok {
						t.Fatalf("update=%t error=%v", ok, err)
					}
					got, err := s.GetStripeWithdrawal(row.ID)
					if err != nil {
						t.Fatal(err)
					}
					want := *before
					change(&want)
					want.UpdatedAt = got.UpdatedAt
					if !reflect.DeepEqual(*got, want) {
						t.Fatalf("changed unrelated fields: got%+v want%+v", *got, want)
					}
					if ok, err := s.CompareAndSwapStripeWithdrawal(before, &next); err != nil || !ok {
						t.Fatalf("idempotent retry=%t error=%v", ok, err)
					}
					duplicate, _ := s.GetStripeWithdrawal(row.ID)
					if !reflect.DeepEqual(got, duplicate) {
						t.Fatalf("idempotent retry mutated row: %+v %+v", got, duplicate)
					}
					stale := *before
					stale.FailureReason = "stale submission"
					if ok, err := s.CompareAndSwapStripeWithdrawal(before, &stale); err != nil || ok {
						t.Fatalf("stale update=%t error=%v", ok, err)
					}
					after, _ := s.GetStripeWithdrawal(row.ID)
					if !reflect.DeepEqual(got, after) {
						t.Fatalf("stale update mutated row: %+v %+v", got, after)
					}
					if want.TransferID != "" {
						if found, err := s.GetStripeWithdrawalByTransferID(want.TransferID); err != nil || found.ID != row.ID {
							t.Fatalf("transfer index: row=%+v error=%v", found, err)
						}
					}
					if want.PayoutID != "" {
						if found, err := s.GetStripeWithdrawalByPayoutID(want.PayoutID); err != nil || found.ID != row.ID {
							t.Fatalf("payout index: row=%+v error=%v", found, err)
						}
					}
					if before.TransferID != want.TransferID {
						if _, err := s.GetStripeWithdrawalByTransferID(before.TransferID); err == nil {
							t.Fatal("old transfer index retained")
						}
					}
					if before.PayoutID != want.PayoutID {
						if _, err := s.GetStripeWithdrawalByPayoutID(before.PayoutID); err == nil {
							t.Fatal("old payout index retained")
						}
					}
					if s.GetBalance(account) != 0 || s.GetWithdrawableBalance(account) != 0 {
						t.Fatal("state update moved balance")
					}
				})
			}
			if ok, err := s.CompareAndSwapStripeWithdrawal(&StripeWithdrawal{ID: "missing"}, &StripeWithdrawal{ID: "missing"}); err != nil || ok {
				t.Fatalf("missing row=%t error=%v", ok, err)
			}
			if ok, err := s.CompareAndSwapStripeWithdrawal(nil, &StripeWithdrawal{ID: "missing"}); err == nil || ok {
				t.Fatalf("nil previous=%t error=%v", ok, err)
			}
		})
	}
}

func TestStripeWithdrawalProgressConcurrentWriters(t *testing.T) {
	for backend, s := range storeBackends(t) {
		t.Run(backend, func(t *testing.T) {
			const account = "progress-race-account"
			if err := s.CreateUser(&User{AccountID: account, PrivyUserID: "did:privy:progress-race"}); err != nil {
				t.Fatal(err)
			}
			row := &StripeWithdrawal{ID: "progress-race", AccountID: account, AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Status: "pending", Method: "standard"}
			if err := s.CreateStripeWithdrawal(row); err != nil {
				t.Fatal(err)
			}
			before, err := s.GetStripeWithdrawal(row.ID)
			if err != nil {
				t.Fatal(err)
			}
			start := make(chan struct{})
			results := make(chan bool, 2)
			errs := make(chan error, 2)
			var wg sync.WaitGroup
			for _, status := range []string{"paid", "failed"} {
				wg.Add(1)
				go func(status string) {
					defer wg.Done()
					next := *before
					next.Status = status
					<-start
					ok, err := s.CompareAndSwapStripeWithdrawal(before, &next)
					results <- ok
					errs <- err
				}(status)
			}
			close(start)
			wg.Wait()
			close(results)
			close(errs)
			count := 0
			for ok := range results {
				if ok {
					count++
				}
			}
			for err := range errs {
				if err != nil {
					t.Fatal(err)
				}
			}
			if count != 1 {
				t.Fatalf("concurrent winners=%d, want1", count)
			}
		})
	}
}
