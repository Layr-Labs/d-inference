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
