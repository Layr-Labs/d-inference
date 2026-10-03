package postgres

import (
	"context"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPostgresRejectedRefundRollsBackWithFlagWrite(t *testing.T) {
	s := testPostgresStore(t)
	w := &store.StripeWithdrawal{ID: "wd-rollback", AccountID: "refund-user", StripeAccountID: "acct_old", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000, Method: "standard", Status: "pending"}
	if err := s.CreditWithdrawable(w.AccountID, 10_000_000, store.LedgerPayout, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateStripeWithdrawalWithDebit(w, store.LedgerStripePayout, "stripe_withdraw:"+w.ID); err != nil {
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
