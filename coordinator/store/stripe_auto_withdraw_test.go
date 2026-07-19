package store

import (
	"errors"
	"testing"
	"time"
)

func TestMemoryStripeAutoWithdrawPreferenceLifecycle(t *testing.T) {
	s := NewMemory(Config{})
	user := &User{AccountID: "acct-auto-pref", PrivyUserID: "did:privy:auto-pref"}
	if err := s.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(user.AccountID, "acct_stripe_a", "ready", "US", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Truncate(time.Second)
	due := now.Add(-time.Hour)
	if err := s.SetStripeAutoWithdraw(user.AccountID, true, now.Add(-2*time.Hour), due); err != nil {
		t.Fatal(err)
	}
	// Re-enabling is idempotent: a repeated UI request cannot postpone the run.
	if err := s.SetStripeAutoWithdraw(user.AccountID, true, now, now.Add(7*24*time.Hour)); err != nil {
		t.Fatal(err)
	}

	got, err := s.GetUserByAccountID(user.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if !got.StripeAutoWithdrawEnabled || got.StripeAutoWithdrawNextAt == nil ||
		!got.StripeAutoWithdrawNextAt.Equal(due) {
		t.Fatalf("preference = %+v, want enabled at original slot %s", got, due)
	}
	users, err := s.ListUsersDueForStripeAutoWithdraw(now, 10)
	if err != nil || len(users) != 1 || users[0].AccountID != user.AccountID {
		t.Fatalf("due users = %+v, err = %v", users, err)
	}

	// A status refresh for the same destination preserves authorization.
	if err := s.SetUserStripeAccount(user.AccountID, "acct_stripe_a", "restricted", "", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}
	got, _ = s.GetUserByAccountID(user.AccountID)
	if !got.StripeAutoWithdrawEnabled {
		t.Fatal("same Stripe destination unexpectedly revoked authorization")
	}
	users, _ = s.ListUsersDueForStripeAutoWithdraw(now, 10)
	if len(users) != 0 {
		t.Fatalf("restricted account returned as due: %+v", users)
	}

	// Authorization is destination-scoped. Replacing the account revokes it.
	if err := s.SetUserStripeAccount(user.AccountID, "acct_stripe_b", "ready", "US", "bank", "9999", false); err != nil {
		t.Fatal(err)
	}
	got, _ = s.GetUserByAccountID(user.AccountID)
	if got.StripeAutoWithdrawEnabled || got.StripeAutoWithdrawAuthorizedAt != nil ||
		got.StripeAutoWithdrawNextAt != nil {
		t.Fatalf("account replacement did not revoke preference: %+v", got)
	}
}

func TestMemoryStripeAutoWithdrawDebitChecksAuthorizationAtomically(t *testing.T) {
	s := NewMemory(Config{})
	user := &User{AccountID: "acct-auto-debit", PrivyUserID: "did:privy:auto-debit"}
	if err := s.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(user.AccountID, "acct_stripe", "ready", "US", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(user.AccountID, 10_000_000, LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Truncate(time.Second)
	slot := now.Add(-time.Minute)
	if err := s.SetStripeAutoWithdraw(user.AccountID, true, now.Add(-time.Hour), slot); err != nil {
		t.Fatal(err)
	}
	newWithdrawal := func(id string) *StripeWithdrawal {
		return &StripeWithdrawal{
			ID: id, AccountID: user.AccountID, StripeAccountID: "acct_stripe",
			AmountMicroUSD: 4_000_000, NetMicroUSD: 4_000_000,
			Method: "standard", Status: "pending",
		}
	}

	err := s.CreateStripeAutoWithdrawalWithDebit(
		newWithdrawal("wd-auto-stale"), LedgerStripePayout, "stripe_withdraw:wd-auto-stale", slot.Add(-time.Hour),
	)
	if !errors.Is(err, ErrAutoWithdrawNotAuthorized) {
		t.Fatalf("stale slot err = %v, want ErrAutoWithdrawNotAuthorized", err)
	}
	if balance := s.GetWithdrawableBalance(user.AccountID); balance != 10_000_000 {
		t.Fatalf("stale worker changed balance to %d", balance)
	}

	wd := newWithdrawal("wd-auto-ok")
	if err := s.CreateStripeAutoWithdrawalWithDebit(
		wd, LedgerStripePayout, "stripe_withdraw:wd-auto-ok", slot,
	); err != nil {
		t.Fatalf("authorized debit: %v", err)
	}
	stored, err := s.GetStripeWithdrawal(wd.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Source != StripeWithdrawalSourceAutomatic || stored.ScheduledFor == nil ||
		!stored.ScheduledFor.Equal(slot) {
		t.Fatalf("automatic metadata = %+v", stored)
	}
	if balance := s.GetWithdrawableBalance(user.AccountID); balance != 6_000_000 {
		t.Fatalf("balance = %d, want 6_000_000", balance)
	}

	// Duplicate schedule IDs roll back before a second debit.
	if err := s.CreateStripeAutoWithdrawalWithDebit(
		newWithdrawal("wd-auto-ok"), LedgerStripePayout, "stripe_withdraw:duplicate", slot,
	); err == nil {
		t.Fatal("duplicate withdrawal ID should fail")
	}
	if balance := s.GetWithdrawableBalance(user.AccountID); balance != 6_000_000 {
		t.Fatalf("duplicate changed balance to %d", balance)
	}

	next := now.Add(7 * 24 * time.Hour)
	advanced, err := s.AdvanceStripeAutoWithdraw(user.AccountID, slot, next)
	if err != nil || !advanced {
		t.Fatalf("advance = %v, err = %v", advanced, err)
	}
	advanced, err = s.AdvanceStripeAutoWithdraw(user.AccountID, slot, next.Add(7*24*time.Hour))
	if err != nil || advanced {
		t.Fatalf("stale advance = %v, err = %v", advanced, err)
	}
}

func TestMemoryListsPendingAutomaticWithdrawals(t *testing.T) {
	s := NewMemory(Config{})
	for _, wd := range []*StripeWithdrawal{
		{
			ID: "auto-pending", AccountID: "a", StripeAccountID: "acct_a",
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "standard", Source: StripeWithdrawalSourceAutomatic, Status: "pending",
		},
		{
			ID: "manual-pending", AccountID: "a", StripeAccountID: "acct_a",
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "standard", Source: StripeWithdrawalSourceManual, Status: "pending",
		},
		{
			ID: "auto-paid", AccountID: "a", StripeAccountID: "acct_a",
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "standard", Source: StripeWithdrawalSourceAutomatic, Status: "paid",
		},
	} {
		if err := s.CreateStripeWithdrawal(wd); err != nil {
			t.Fatal(err)
		}
	}

	rows, err := s.ListStripeWithdrawalsBySourceStatus(
		StripeWithdrawalSourceAutomatic, "pending", 10,
	)
	if err != nil || len(rows) != 1 || rows[0].ID != "auto-pending" {
		t.Fatalf("rows = %+v, err = %v", rows, err)
	}
}
