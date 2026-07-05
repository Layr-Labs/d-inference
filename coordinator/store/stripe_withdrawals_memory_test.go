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
