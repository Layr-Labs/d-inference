package store

import (
	"context"
	"fmt"
	"sync"
	"testing"
)

func stripeReversalFixture(t *testing.T, s Store, id string) *StripeWithdrawal {
	t.Helper()
	wd := &StripeWithdrawal{ID: id, AccountID: "acct-" + id, StripeAccountID: "acct_stripe_" + id,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "transferred", TransferID: "tr_" + id, PayoutID: "po_" + id}
	if err := s.CreateUser(&User{AccountID: wd.AccountID, PrivyUserID: "did:privy:" + wd.AccountID}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateStripeWithdrawal(wd); err != nil {
		t.Fatal(err)
	}
	return wd
}

func TestStripeReversalSerializesWithPaidAndFeeRefund(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for i := 0; i < 12; i++ {
				wd := stripeReversalFixture(t, s, fmt.Sprintf("reversal-race-%d", i))
				var wg sync.WaitGroup
				start := make(chan struct{})
				for _, operation := range []func() error{
					func() error { _, err := s.MarkStripeWithdrawalPaid(wd.ID, wd.PayoutID, ""); return err },
					func() error { _, err := s.RefundStripeWithdrawalAfterReversal(wd.ID, wd.TransferID); return err },
				} {
					wg.Add(1)
					go func(fn func() error) {
						defer wg.Done()
						<-start
						if err := fn(); err != nil {
							t.Error(err)
						}
					}(operation)
				}
				close(start)
				wg.Wait()
				got, err := s.GetStripeWithdrawal(wd.ID)
				if err != nil {
					t.Fatal(err)
				}
				balance, withdrawable := s.GetBalanceWithWithdrawable(wd.AccountID)
				if got.Status == "paid" {
					if got.Refunded || balance != 0 || withdrawable != 0 {
						t.Fatalf("paid row was refunded: %+v balance=%d/%d", got, balance, withdrawable)
					}
				} else if got.Status != "failed" || !got.Refunded || balance != wd.AmountMicroUSD || withdrawable != balance {
					t.Fatalf("reversal not atomic: %+v balance=%d/%d", got, balance, withdrawable)
				}
			}
			wd := stripeReversalFixture(t, s, "reversal-fee-race")
			var wg sync.WaitGroup
			for i := 0; i < 12; i++ {
				wg.Add(2)
				go func() {
					defer wg.Done()
					if _, err := s.RefundStripeWithdrawalAfterReversal(wd.ID, wd.TransferID); err != nil {
						t.Error(err)
					}
				}()
				go func() {
					defer wg.Done()
					if _, err := s.CreditWithdrawableOnce(wd.AccountID, wd.FeeMicroUSD, LedgerRefund, "stripe_withdraw_fee:"+wd.ID); err != nil {
						t.Error(err)
					}
				}()
			}
			wg.Wait()
			got, err := s.GetStripeWithdrawal(wd.ID)
			if err != nil {
				t.Fatal(err)
			}
			if balance := s.GetBalance(wd.AccountID); balance != wd.AmountMicroUSD || !got.Refunded || !got.FeeRefunded {
				t.Fatalf("fee/refund replay double-credited: balance=%d row=%+v", balance, got)
			}
		})
	}
}

func TestPostgresStripeReversalRollsBackCreditsWhenRowWriteFails(t *testing.T) {
	s := testPostgresStore(t)
	wd := stripeReversalFixture(t, s, "reversal-rollback")
	ctx := context.Background()
	_, err := s.pool.Exec(ctx, `ALTER TABLE stripe_withdrawals ADD CONSTRAINT test_reversal_write CHECK (id <> 'reversal-rollback' OR NOT refunded)`)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = s.pool.Exec(ctx, `ALTER TABLE stripe_withdrawals DROP CONSTRAINT IF EXISTS test_reversal_write`)
	})
	if _, err := s.RefundStripeWithdrawalAfterReversal(wd.ID, wd.TransferID); err == nil {
		t.Fatal("expected row constraint failure")
	}
	got, err := s.GetStripeWithdrawal(wd.ID)
	if err != nil {
		t.Fatal(err)
	}
	if balance := s.GetBalance(wd.AccountID); balance != 0 || got.Refunded || got.Status != "transferred" {
		t.Fatalf("failed commit left partial refund: balance=%d row=%+v", balance, got)
	}
	if _, err := s.pool.Exec(ctx, `ALTER TABLE stripe_withdrawals DROP CONSTRAINT test_reversal_write`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err := s.RefundStripeWithdrawalAfterReversal(wd.ID, wd.TransferID); err != nil {
			t.Fatal(err)
		}
	}
	if balance, withdrawable := s.GetBalanceWithWithdrawable(wd.AccountID); balance != wd.AmountMicroUSD || withdrawable != balance {
		t.Fatalf("retry refund = %d/%d", balance, withdrawable)
	}
}
