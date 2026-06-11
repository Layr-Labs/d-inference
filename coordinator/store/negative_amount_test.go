package store

// Regression tests for the store-layer defense against negative-amount Debit
// and Credit calls (layer 4 of the balance-minting fix).
//
// Without the fix:
//   - Debit(-N): `balance < -N` is false for any positive balance, so it passes
//     the guard, then balance -= -N adds N to the balance (minting).
//   - Credit(-N): creditLocked adds -N, subtracting from balance (destruction
//     and potentially wrapping negative).
//
// With the fix: both return ErrNegativeAmount before touching balances.

import (
	"errors"
	"testing"
)

func TestDebitNegativeAmountReturnsError(t *testing.T) {
	s := NewMemory(Config{})
	const acct = "neg-debit-acct"
	const seed int64 = 1_000_000

	// Seed a positive balance.
	if err := s.Credit(acct, seed, LedgerDeposit, "seed"); err != nil {
		t.Fatalf("seed credit: %v", err)
	}
	before := s.GetBalance(acct)
	if before != seed {
		t.Fatalf("seeded balance = %d, want %d", before, seed)
	}

	// Debit with a negative amount must be rejected.
	err := s.Debit(acct, -500_000, LedgerCharge, "neg-debit")
	if !errors.Is(err, ErrNegativeAmount) {
		t.Errorf("Debit(-500000) error = %v, want ErrNegativeAmount", err)
	}

	// Balance must be unchanged — negative debit must NOT mint balance.
	after := s.GetBalance(acct)
	if after != before {
		t.Errorf("Debit(-500000) changed balance from %d to %d (minted %d)",
			before, after, after-before)
	}
}

func TestCreditNegativeAmountReturnsError(t *testing.T) {
	s := NewMemory(Config{})
	const acct = "neg-credit-acct"
	const seed int64 = 1_000_000

	if err := s.Credit(acct, seed, LedgerDeposit, "seed"); err != nil {
		t.Fatalf("seed credit: %v", err)
	}
	before := s.GetBalance(acct)

	// Credit with a negative amount must be rejected.
	err := s.Credit(acct, -999_999, LedgerRefund, "neg-credit")
	if !errors.Is(err, ErrNegativeAmount) {
		t.Errorf("Credit(-999999) error = %v, want ErrNegativeAmount", err)
	}

	// Balance must be unchanged — negative credit must NOT subtract balance.
	after := s.GetBalance(acct)
	if after != before {
		t.Errorf("Credit(-999999) changed balance from %d to %d (diff %d)",
			before, after, after-before)
	}
}

// TestDebitNegativeAmountLargePositiveBalance ensures the old guard
// `balance < amount` did NOT protect against negative amounts (because a
// positive balance is never < a negative amount). This test captures the
// failure mode explicitly: a very large negative debit on a modest balance.
func TestDebitNegativeAmountLargeBalance(t *testing.T) {
	s := NewMemory(Config{})
	const acct = "neg-debit-large-acct"
	const seed int64 = 100_000_000 // $100

	if err := s.Credit(acct, seed, LedgerDeposit, "seed"); err != nil {
		t.Fatalf("seed credit: %v", err)
	}
	before := s.GetBalance(acct)

	// Debit a very large negative amount — without the fix this would add a
	// huge positive value to the balance.
	err := s.Debit(acct, -999_999_999_999, LedgerCharge, "large-neg-debit")
	if !errors.Is(err, ErrNegativeAmount) {
		t.Errorf("Debit(-999999999999) error = %v, want ErrNegativeAmount", err)
	}

	after := s.GetBalance(acct)
	if after != before {
		t.Errorf("Debit(-999999999999) minted balance: %d -> %d (minted %d)",
			before, after, after-before)
	}
}

// TestPositiveAmountsStillWork ensures the fix does not break normal positive
// Debit and Credit operations.
func TestPositiveAmountsStillWork(t *testing.T) {
	s := NewMemory(Config{})
	const acct = "positive-ops-acct"

	// Credit positive.
	if err := s.Credit(acct, 1_000_000, LedgerDeposit, "seed"); err != nil {
		t.Fatalf("positive Credit failed: %v", err)
	}
	if got := s.GetBalance(acct); got != 1_000_000 {
		t.Errorf("after Credit(1000000): balance = %d, want 1000000", got)
	}

	// Debit positive.
	if err := s.Debit(acct, 400_000, LedgerCharge, "charge"); err != nil {
		t.Fatalf("positive Debit failed: %v", err)
	}
	if got := s.GetBalance(acct); got != 600_000 {
		t.Errorf("after Debit(400000): balance = %d, want 600000", got)
	}

	// Zero amount: Debit(0) and Credit(0) should succeed (no-op).
	if err := s.Debit(acct, 0, LedgerCharge, "zero"); err != nil {
		t.Errorf("Debit(0) unexpectedly failed: %v", err)
	}
	if err := s.Credit(acct, 0, LedgerRefund, "zero"); err != nil {
		t.Errorf("Credit(0) unexpectedly failed: %v", err)
	}
}
