package store

import (
	"context"
	"sync"
	"testing"
	"time"
)

func TestStripeSettlementRecoveryContract(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			repo, ok := As[StripeSettlementStore](s)
			if !ok {
				t.Fatal("missing settlement store")
			}
			w := &StripeWithdrawal{ID: "wd-reject", AccountID: "refund-user", StripeAccountID: "acct_old", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Method: "standard", Status: "pending"}
			if err := s.CreditWithdrawable(w.AccountID, 10_000_000, LedgerPayout, "seed"); err != nil {
				t.Fatal(err)
			}
			if err := s.CreateStripeWithdrawalWithDebit(w, LedgerStripePayout, "stripe_withdraw:"+w.ID); err != nil {
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
			bs := &BillingSession{ID: "cs-local", AccountID: "buyer", PaymentMethod: "stripe", AmountMicroUSD: 7_000_000, ExternalID: "cs_external", Status: "pending", CreatedAt: time.Now()}
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

func TestPostgresRejectedRefundRollsBackWithFlagWrite(t *testing.T) {
	s := testPostgresStore(t)
	w := &StripeWithdrawal{ID: "wd-rollback", AccountID: "refund-user", StripeAccountID: "acct_old", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Method: "standard", Status: "pending"}
	if err := s.CreditWithdrawable(w.AccountID, 10_000_000, LedgerPayout, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateStripeWithdrawalWithDebit(w, LedgerStripePayout, "stripe_withdraw:"+w.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordStripeTransferRejection(w.ID, "rejected"); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := s.pool.Exec(ctx, `ALTER TABLE stripe_withdrawals ADD CONSTRAINT reject_refund_flag CHECK (NOT refunded)`); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = s.pool.Exec(ctx, `ALTER TABLE stripe_withdrawals DROP CONSTRAINT IF EXISTS reject_refund_flag`)
	})
	if _, err := s.RefundRejectedStripeWithdrawal(w.ID); err == nil {
		t.Fatal("expected flag constraint failure")
	}
	if s.GetBalance(w.AccountID) != 5_000_000 {
		t.Fatal("credit escaped rolled-back transaction")
	}
	if _, err := s.pool.Exec(ctx, `ALTER TABLE stripe_withdrawals DROP CONSTRAINT reject_refund_flag`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RefundRejectedStripeWithdrawal(w.ID); err != nil {
		t.Fatal(err)
	}
	if s.GetBalance(w.AccountID) != 10_000_000 {
		t.Fatal("refund did not recover")
	}
}

func TestResetGlobalRecipientFencesOldOnboardingAndQuotes(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			g, _ := As[GlobalPayoutStore](s)
			p := payoutFixture(t, s, g, "reset-user", "reset-quote")
			old, _ := g.GetGlobalRecipient(p.AccountID)
			if err := g.RemoveGlobalRecipient(p.AccountID); err != nil {
				t.Fatal(err)
			}
			next, err := g.GetGlobalRecipient(p.AccountID)
			if err != nil || next.ID == old.ID || next.RecipientID != "" || next.Ready {
				t.Fatalf("reset lost fence: %+v %v", next, err)
			}
			if err := g.SaveGlobalRecipient(*old); err != ErrPayoutConflict {
				t.Fatalf("stale onboarding write: %v", err)
			}
			if _, err := g.BeginGlobalPayout(p.AccountID, p.ID, time.Now()); err != ErrPayoutConflict {
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
			r, _ := As[StripeSettlementStore](s)
			// A legacy handler may have credited before its session write completed.
			if err := s.Credit("buyer-old", 3_000_000, LedgerStripeDeposit, "stripe:cs_legacy"); err != nil {
				t.Fatal(err)
			}
			if err := s.CreateBillingSession(&BillingSession{ID: "local-old", ExternalID: "cs_legacy", AccountID: "buyer-old", PaymentMethod: "stripe", Status: "pending", AmountMicroUSD: 3_000_000, CreatedAt: time.Now()}); err != nil {
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
