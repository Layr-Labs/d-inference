package store

import (
	"errors"
	"testing"
)

// TestMemoryStripeWithdrawalFeeRefundedRoundTrip pins the FeeRefunded flag —
// the idempotency key for instant-fee refunds — through create/update/get.
func TestMemoryStripeWithdrawalFeeRefundedRoundTrip(t *testing.T) {
	s := NewMemory(Config{})
	wd := &StripeWithdrawal{
		ID: "wd-fee-rt", AccountID: "acct-1", StripeAccountID: "acct_x",
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "transferred", PayoutID: "po_rt",
	}
	if err := s.CreateStripeWithdrawal(wd); err != nil {
		t.Fatalf("create: %v", err)
	}

	got, err := s.GetStripeWithdrawal("wd-fee-rt")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.FeeRefunded {
		t.Error("FeeRefunded should default to false")
	}

	// Refund the fee and detach the payout (async instant-failure path).
	got.FeeRefunded = true
	got.PayoutID = ""
	if err := s.UpdateStripeWithdrawal(got); err != nil {
		t.Fatalf("update: %v", err)
	}
	again, _ := s.GetStripeWithdrawal("wd-fee-rt")
	if !again.FeeRefunded {
		t.Error("FeeRefunded not persisted")
	}
	// The detached payout ID must no longer resolve to the row.
	if _, err := s.GetStripeWithdrawalByPayoutID("po_rt"); !errors.Is(err, ErrNotFound) {
		t.Errorf("detached payout lookup err = %v, want ErrNotFound", err)
	}
}

// TestMemoryStripeWithdrawalLookupNotFound pins the ErrNotFound sentinel the
// webhook state machine relies on to distinguish a true miss from a
// transient store failure.
func TestMemoryStripeWithdrawalLookupNotFound(t *testing.T) {
	s := NewMemory(Config{})
	if _, err := s.GetStripeWithdrawalByPayoutID("po_missing"); !errors.Is(err, ErrNotFound) {
		t.Errorf("payout lookup err = %v, want ErrNotFound", err)
	}
	if _, err := s.GetStripeWithdrawalByTransferID("tr_missing"); !errors.Is(err, ErrNotFound) {
		t.Errorf("transfer lookup err = %v, want ErrNotFound", err)
	}
}

// TestMemoryCreditWithdrawableOnce pins the reference-idempotent credit that
// webhook-driven refunds rely on to survive redelivery.
func TestMemoryCreditWithdrawableOnce(t *testing.T) {
	s := NewMemory(Config{})

	applied, err := s.CreditWithdrawableOnce("acct-once", 500_000, LedgerRefund, "stripe_withdraw_fee:wd-1")
	if err != nil || !applied {
		t.Fatalf("first credit: applied=%v err=%v", applied, err)
	}
	applied, err = s.CreditWithdrawableOnce("acct-once", 500_000, LedgerRefund, "stripe_withdraw_fee:wd-1")
	if err != nil || applied {
		t.Fatalf("duplicate credit: applied=%v err=%v, want skipped", applied, err)
	}
	if bal := s.GetBalance("acct-once"); bal != 500_000 {
		t.Errorf("balance = %d, want 500_000 (credited exactly once)", bal)
	}

	// A different reference on the same account still credits.
	if applied, _ = s.CreditWithdrawableOnce("acct-once", 4_500_000, LedgerRefund, "stripe_withdraw:wd-1"); !applied {
		t.Error("different reference should credit")
	}
	// Same reference but a different entry type is a distinct key (the
	// withdrawal debit reuses the refund's reference string).
	if applied, _ = s.CreditWithdrawableOnce("acct-once", 100, LedgerDeposit, "stripe_withdraw:wd-1"); !applied {
		t.Error("different entry type should credit")
	}
	if bal := s.GetBalance("acct-once"); bal != 5_000_100 {
		t.Errorf("balance = %d, want 5_000_100", bal)
	}
}

// --- CreateStripeWithdrawalWithDebit (atomic debit + row insert) ---

func TestMemoryCreateStripeWithdrawalWithDebit(t *testing.T) {
	s := NewMemory(Config{})
	if err := s.CreditWithdrawable("acct-wdb", 10_000_000, LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}

	wd := &StripeWithdrawal{
		ID: "wd-atomic-1", AccountID: "acct-wdb", StripeAccountID: "acct_wdb",
		AmountMicroUSD: 4_000_000, NetMicroUSD: 4_000_000,
		Method: "standard", Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(wd, LedgerStripePayout, "stripe_withdraw:wd-atomic-1"); err != nil {
		t.Fatalf("atomic debit+insert: %v", err)
	}
	if bal := s.GetBalance("acct-wdb"); bal != 6_000_000 {
		t.Errorf("balance = %d, want 6_000_000", bal)
	}
	if _, wdr := s.GetBalanceWithWithdrawable("acct-wdb"); wdr != 6_000_000 {
		t.Errorf("withdrawable = %d, want 6_000_000", wdr)
	}
	row, err := s.GetStripeWithdrawal("wd-atomic-1")
	if err != nil || row.Status != "pending" {
		t.Fatalf("row = %+v err = %v", row, err)
	}

	// Insufficient withdrawable: typed error, no debit, no row.
	wd2 := &StripeWithdrawal{
		ID: "wd-atomic-2", AccountID: "acct-wdb", StripeAccountID: "acct_wdb",
		AmountMicroUSD: 60_000_000, NetMicroUSD: 60_000_000,
		Method: "standard", Status: "pending",
	}
	err = s.CreateStripeWithdrawalWithDebit(wd2, LedgerStripePayout, "stripe_withdraw:wd-atomic-2")
	if !errors.Is(err, ErrInsufficientBalance) {
		t.Fatalf("err = %v, want ErrInsufficientBalance", err)
	}
	if bal := s.GetBalance("acct-wdb"); bal != 6_000_000 {
		t.Errorf("failed attempt moved the balance: %d", bal)
	}
	if _, err := s.GetStripeWithdrawal("wd-atomic-2"); err == nil {
		t.Error("row must not exist after a failed debit")
	}

	// Duplicate ID: rejected without debiting.
	dup := &StripeWithdrawal{
		ID: "wd-atomic-1", AccountID: "acct-wdb", StripeAccountID: "acct_wdb",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(dup, LedgerStripePayout, "stripe_withdraw:dup"); err == nil {
		t.Fatal("duplicate ID must fail")
	}
	if bal := s.GetBalance("acct-wdb"); bal != 6_000_000 {
		t.Errorf("duplicate attempt moved the balance: %d", bal)
	}
}

// TestMemoryMarkStripeWithdrawalPaidGuards pins the store-side guard that
// closes the paid-vs-refund webhook race: only non-terminal, non-refunded
// rows flip to paid.
func TestMemoryMarkStripeWithdrawalPaidGuards(t *testing.T) {
	s := NewMemory(Config{})
	mk := func(id, status string, refunded bool) {
		if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
			ID: id, AccountID: "acct-mp", StripeAccountID: "acct_mp",
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "standard", Status: status, Refunded: refunded,
		}); err != nil {
			t.Fatal(err)
		}
	}

	mk("wd-mp-ok", "transferred", false)
	if applied, err := s.MarkStripeWithdrawalPaid("wd-mp-ok", "", "po_sweep_1"); err != nil || !applied {
		t.Fatalf("transferred row: applied=%v err=%v, want applied", applied, err)
	}
	row, _ := s.GetStripeWithdrawal("wd-mp-ok")
	if row.Status != "paid" || row.SweepPayoutID != "po_sweep_1" {
		t.Errorf("row = %q/%q, want paid/po_sweep_1", row.Status, row.SweepPayoutID)
	}

	mk("wd-mp-refunded", "transferred", true)
	if applied, _ := s.MarkStripeWithdrawalPaid("wd-mp-refunded", "", ""); applied {
		t.Error("refunded row must not flip to paid")
	}
	mk("wd-mp-failed", "failed", false)
	if applied, _ := s.MarkStripeWithdrawalPaid("wd-mp-failed", "", ""); applied {
		t.Error("failed row must not flip to paid")
	}
	if _, err := s.MarkStripeWithdrawalPaid("wd-mp-missing", "", ""); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing row err = %v, want ErrNotFound", err)
	}

	// Payout-ID condition: a row whose in-flight payout was detached (or
	// replaced) concurrently must not flip for the stale event.
	if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
		ID: "wd-mp-detached", AccountID: "acct-mp", StripeAccountID: "acct_mp",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "instant", Status: "transferred",
	}); err != nil {
		t.Fatal(err)
	}
	if applied, _ := s.MarkStripeWithdrawalPaid("wd-mp-detached", "po_gone", ""); applied {
		t.Error("row without the expected payout ID must not flip to paid")
	}
	if applied, _ := s.MarkStripeWithdrawalPaid("wd-mp-detached", "", ""); !applied {
		t.Error("row with no in-flight payout should flip for the sweep case")
	}

	// Sweep-stamp lookup returns exactly the stamped rows.
	rows, err := s.ListStripeWithdrawalsBySweepPayoutID("po_sweep_1")
	if err != nil || len(rows) != 1 || rows[0].ID != "wd-mp-ok" {
		t.Errorf("sweep lookup = %v (err %v), want [wd-mp-ok]", rows, err)
	}
}

// TestMemoryReopenStripeWithdrawalAfterPayoutFailureGuards pins the guarded
// bounce-reopen: refunded/terminal rows are never reopened (a concurrent
// transfer.reversed wins), live rows reopen with the payout detached.
func TestMemoryReopenStripeWithdrawalAfterPayoutFailureGuards(t *testing.T) {
	s := NewMemory(Config{})
	mk := func(id, status, payoutID string, refunded bool) {
		if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
			ID: id, AccountID: "acct-ro", StripeAccountID: "acct_ro",
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "instant", Status: status, PayoutID: payoutID, Refunded: refunded,
		}); err != nil {
			t.Fatal(err)
		}
	}

	mk("wd-ro-ok", "paid", "po_ro1", false)
	applied, err := s.ReopenStripeWithdrawalAfterPayoutFailure("wd-ro-ok", "payout_failed: bounce", true)
	if err != nil || !applied {
		t.Fatalf("live row: applied=%v err=%v, want applied", applied, err)
	}
	row, _ := s.GetStripeWithdrawal("wd-ro-ok")
	if row.Status != "transferred" || row.PayoutID != "" || !row.FeeRefunded {
		t.Errorf("row = %q/%q/feeRefunded=%v, want transferred/empty/true", row.Status, row.PayoutID, row.FeeRefunded)
	}
	// Detached payout ID must leave the lookup index.
	if _, err := s.GetStripeWithdrawalByPayoutID("po_ro1"); !errors.Is(err, ErrNotFound) {
		t.Errorf("detached payout lookup err = %v, want ErrNotFound", err)
	}

	mk("wd-ro-refunded", "transferred", "po_ro2", true)
	if applied, _ := s.ReopenStripeWithdrawalAfterPayoutFailure("wd-ro-refunded", "x", false); applied {
		t.Error("refunded row must not reopen (reversal owns it)")
	}
	mk("wd-ro-failed", "failed", "", false)
	if applied, _ := s.ReopenStripeWithdrawalAfterPayoutFailure("wd-ro-failed", "x", false); applied {
		t.Error("failed row must not reopen")
	}
}
