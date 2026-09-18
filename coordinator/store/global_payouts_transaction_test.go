package store

import (
	"context"
	"testing"
	"time"
)

// A payout-row write can fail after the refund ledger write. Both must roll
// back together so reconciliation can retry without duplicating the refund.
func TestPostgresGlobalPayoutRefundRollsBackWhenPayoutWriteFails(t *testing.T) {
	s := testPostgresStore(t)
	now := time.Now()
	first := payoutFixture(t, s, s, "gp-first", "gp-first")
	second := payoutFixture(t, s, s, "gp-second", "gp-second")
	for _, p := range []GlobalPayout{first, second} {
		if _, err := s.BeginGlobalPayout(p.AccountID, p.ID, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.ApplyGlobalPayout(first.ID, GlobalPayoutResult{Status: "posted", ExternalID: "obp_first"}, now); err != nil {
		t.Fatal(err)
	}
	// The existing unique external-ID constraint rejects persistence only after
	// ApplyGlobalPayout has attempted the refund in the same transaction.
	if err := s.ApplyGlobalPayout(second.ID, GlobalPayoutResult{Status: "returned", ExternalID: "obp_first"}, now); err == nil {
		t.Fatal("expected duplicate external payment ID to reject the payout write")
	}
	got, err := s.GetGlobalPayout(second.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Status != "pending" || got.Refunded || got.ExternalID != "" {
		t.Fatalf("failed transaction changed payout: %+v", got)
	}
	if balance, withdrawable := s.GetBalanceWithWithdrawable(second.AccountID); balance != 2_000_000 || withdrawable != balance {
		t.Fatalf("failed transaction refunded money: %d/%d", balance, withdrawable)
	}
	for range 2 {
		if err := s.ApplyGlobalPayout(second.ID, GlobalPayoutResult{Status: "returned", ExternalID: "obp_second"}, now); err != nil {
			t.Fatal(err)
		}
	}
	if balance, withdrawable := s.GetBalanceWithWithdrawable(second.AccountID); balance != 10_000_000 || withdrawable != balance {
		t.Fatalf("retry did not refund exactly once: %d/%d", balance, withdrawable)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var refunds int
	if err := s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM ledger_entries WHERE reference=$1`, "global_payout_refund:"+second.ID).Scan(&refunds); err != nil {
		t.Fatal(err)
	}
	if refunds != 1 {
		t.Fatalf("refund ledger entries=%d, want 1", refunds)
	}
}
