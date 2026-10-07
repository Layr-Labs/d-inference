package postgres_test

import (
	"context"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestPostgresStripeRefundLookupUsesReferenceIndex(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	// A busy account must not scan its lifetime payout history to refund one withdrawal.
	if _, err := s.pool.Exec(ctx, `INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
 SELECT 'busy-provider', 'stripe_payout', -5000000, 0, 'stripe_withdraw:history-' || n FROM generate_series(1, 100000) n`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `ANALYZE ledger_entries`); err != nil {
		t.Fatal(err)
	}
	rows, err := s.pool.Query(ctx, `EXPLAIN (ANALYZE, BUFFERS) SELECT COALESCE(SUM(amount_micro_usd) FILTER (WHERE entry_type='refund'),0), COALESCE(SUM(amount_micro_usd) FILTER (WHERE entry_type='stripe_payout'),0) FROM ledger_entries WHERE account_id=$1 AND reference=$2 AND entry_type IN ('refund','stripe_payout')`, "busy-provider", "stripe_withdraw:history-50000")
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var plan strings.Builder
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		plan.WriteString(line + "\n")
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	t.Log(plan.String())
	if !strings.Contains(plan.String(), "idx_ledger_stripe_refund") || !strings.Contains(plan.String(), "Index Cond:") || !strings.Contains(plan.String(), "reference =") {
		t.Fatalf("refund lookup must use an account/reference index:\n%s", plan.String())
	}
}

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
	if b, wd := s.GetBalanceWithWithdrawable(w.AccountID); b != 5_000_000 || wd != b {
		t.Fatalf("credit escaped rolled-back transaction: %d/%d", b, wd)
	}
	stored, err := s.GetStripeWithdrawal(w.ID)
	if err != nil || stored.Refunded {
		t.Fatalf("refund flag escaped rolled-back transaction: %+v %v", stored, err)
	}
	var refunds int
	if err := s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM ledger_entries WHERE account_id=$1 AND reference=$2 AND entry_type='refund'`, w.AccountID, "stripe_withdraw:"+w.ID).Scan(&refunds); err != nil || refunds != 0 {
		t.Fatalf("ledger credit escaped rolled-back transaction: count=%d err=%v", refunds, err)
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
