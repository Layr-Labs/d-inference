package store_test

import (
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStripeSettlementRecoveryContract(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			repo, ok := store.As[store.StripeSettlementStore](s)
			if !ok {
				t.Fatal("missing settlement store")
			}
			w := &store.StripeWithdrawal{ID: "wd-reject", AccountID: "refund-user", StripeAccountID: "acct_old", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Method: "standard", Status: "pending"}
			if err := s.CreditWithdrawable(w.AccountID, 10_000_000, store.LedgerPayout, "seed"); err != nil {
				t.Fatal(err)
			}
			if err := s.CreateStripeWithdrawalWithDebit(w, store.LedgerStripePayout, "stripe_withdraw:"+w.ID); err != nil {
				t.Fatal(err)
			}
			if _, err := repo.RefundRejectedStripeWithdrawal(w.ID); err == nil {
				t.Fatal("refunded unconfirmed transfer")
			}
			if err := repo.RecordStripeTransferRejection(w.ID, "stripe 400 [balance_insufficient]"); err != nil {
				t.Fatal(err)
			}
			rows, err := repo.ListStripeRefundsToRecover(10)
			if err != nil || len(rows) != 1 {
				t.Fatalf("recovery scan %v %v", rows, err)
			}
			var wg sync.WaitGroup
			for range 8 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if _, err := repo.RefundRejectedStripeWithdrawal(w.ID); err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			if b, wd := s.GetBalanceWithWithdrawable(w.AccountID); b != 10_000_000 || wd != b {
				t.Fatalf("refund duplicated or lost: %d/%d", b, wd)
			}
			rows, err = repo.ListStripeRefundsToRecover(10)
			if err != nil || len(rows) != 0 {
				t.Fatal("refunded row remained eligible")
			}
			bs := &store.BillingSession{ID: "cs-local", AccountID: "buyer", PaymentMethod: "stripe", AmountMicroUSD: 7_000_000, ExternalID: "cs_external", Status: "pending", CreatedAt: time.Now()}
			if err := s.CreateBillingSession(bs); err != nil {
				t.Fatal(err)
			}
			if _, err := repo.CompleteStripeCheckout(bs.ID, bs.ExternalID, "other", bs.AmountMicroUSD); err == nil {
				t.Fatal("credited wrong user")
			}
			for range 8 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					if _, err := repo.CompleteStripeCheckout(bs.ID, bs.ExternalID, bs.AccountID, bs.AmountMicroUSD); err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			if b, wd := s.GetBalanceWithWithdrawable(bs.AccountID); b != 7_000_000 || wd != 0 {
				t.Fatalf("deposit duplicated or became withdrawable: %d/%d", b, wd)
			}
		})
	}
}

func TestResetGlobalRecipientFencesOldOnboardingAndQuotes(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := store.As[store.GlobalPayoutStore](s)
			p := payoutFixture(t, s, g, "reset-user", "reset-quote")
			old, _ := g.GetGlobalRecipient(p.AccountID)
			if err := g.RemoveGlobalRecipient(p.AccountID); err != nil {
				t.Fatal(err)
			}
			next, err := g.GetGlobalRecipient(p.AccountID)
			if err != nil || next.ID == old.ID || next.RecipientID != "" || next.Ready {
				t.Fatalf("reset lost fence: %+v %v", next, err)
			}
			if err := g.SaveGlobalRecipient(*old); err != store.ErrPayoutConflict {
				t.Fatalf("stale onboarding write: %v", err)
			}
			if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, time.Now()); err != store.ErrPayoutConflict {
				t.Fatalf("old quote accepted: %v", err)
			}
			if s.GetBalance(p.AccountID) != 10_000_000 {
				t.Fatal("old quote debited")
			}
		})
	}
}

func TestCheckoutRecoversPreExistingCreditWithoutDoubling(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			r, _ := store.As[store.StripeSettlementStore](s)
			// A legacy handler may have credited before its session write completed.
			if err := s.Credit("buyer-old", 3_000_000, store.LedgerStripeDeposit, "stripe:cs_legacy"); err != nil {
				t.Fatal(err)
			}
			if err := s.CreateBillingSession(&store.BillingSession{ID: "local-old", ExternalID: "cs_legacy", AccountID: "buyer-old", PaymentMethod: "stripe", Status: "pending", AmountMicroUSD: 3_000_000, CreatedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			if _, err := r.CompleteStripeCheckout("local-old", "cs_legacy", "buyer-old", 3_000_000); err != nil {
				t.Fatal(err)
			}
			if s.GetBalance("buyer-old") != 3_000_000 {
				t.Fatal("legacy credit doubled")
			}
			b, _ := s.GetBillingSession("local-old")
			if b.Status != "completed" {
				t.Fatal("session not completed")
			}
		})
	}
}

// The coordinator stamps a withdrawal with its own clock, and Postgres stamps
// the debit and refund ledger entries with the database clock. A coordinator
// clock that runs ahead of the database must not hide those entries from the
// refund check: hiding the debit loses the refund, and hiding an earlier
// refund duplicates it.
func TestStripeRefundIgnoresCoordinatorClockAheadOfLedger(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			repo, _ := store.As[store.StripeSettlementStore](s)
			stampedAhead := time.Now().Add(time.Minute)
			rejected := func(id string) *store.StripeWithdrawal {
				t.Helper()
				w := &store.StripeWithdrawal{ID: id, AccountID: "skew-" + id, StripeAccountID: "acct_old", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Method: "standard", Status: "pending", CreatedAt: stampedAhead}
				if err := s.CreditWithdrawable(w.AccountID, 10_000_000, store.LedgerPayout, "seed"); err != nil {
					t.Fatal(err)
				}
				if err := s.CreateStripeWithdrawalWithDebit(w, store.LedgerStripePayout, "stripe_withdraw:"+w.ID); err != nil {
					t.Fatal(err)
				}
				if err := repo.RecordStripeTransferRejection(w.ID, "stripe 400 [balance_insufficient]"); err != nil {
					t.Fatal(err)
				}
				return w
			}

			lost := rejected("wd-skew-debit")
			if applied, err := repo.RefundRejectedStripeWithdrawal(lost.ID); err != nil || !applied {
				t.Fatalf("refund: applied=%v err=%v", applied, err)
			}
			if applied, err := repo.RefundRejectedStripeWithdrawal(lost.ID); err != nil || applied {
				t.Fatalf("repeated refund: applied=%v err=%v", applied, err)
			}
			if b, wd := s.GetBalanceWithWithdrawable(lost.AccountID); b != 10_000_000 || wd != b {
				t.Fatalf("refund duplicated or lost: %d/%d", b, wd)
			}

			legacy := rejected("wd-skew-legacy")
			if applied, err := s.CreditWithdrawableOnce(legacy.AccountID, legacy.AmountMicroUSD, store.LedgerRefund, "stripe_withdraw:"+legacy.ID); err != nil || !applied {
				t.Fatalf("legacy refund: applied=%v err=%v", applied, err)
			}
			if applied, err := repo.RefundRejectedStripeWithdrawal(legacy.ID); err != nil || applied {
				t.Fatalf("legacy refund recovery: applied=%v err=%v", applied, err)
			}
			if b, wd := s.GetBalanceWithWithdrawable(legacy.AccountID); b != 10_000_000 || wd != b {
				t.Fatalf("legacy refund duplicated or lost: %d/%d", b, wd)
			}
			if rows, err := repo.ListStripeRefundsToRecover(10); err != nil || len(rows) != 0 {
				t.Fatalf("refunded rows remained eligible: %v %v", rows, err)
			}
		})
	}
}
