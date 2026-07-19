package store

import (
	"errors"
	"fmt"
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
	if err := s.SetStripeAutoWithdraw(user.AccountID, "acct_stripe_a", true, now.Add(-2*time.Hour), due); err != nil {
		t.Fatal(err)
	}
	// Re-enabling is idempotent: a repeated UI request cannot postpone the run.
	if err := s.SetStripeAutoWithdraw(user.AccountID, "acct_stripe_a", true, now, now.Add(7*24*time.Hour)); err != nil {
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

func TestMemoryStripeAutoWithdrawDuePagination(t *testing.T) {
	s := NewMemory(Config{})
	now := time.Now().UTC().Truncate(time.Second)
	slot := now.Add(-time.Hour)
	for _, accountID := range []string{"acct-page-a", "acct-page-b", "acct-page-c"} {
		user := &User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID}
		if err := s.CreateUser(user); err != nil {
			t.Fatal(err)
		}
		stripeID := "stripe_" + accountID
		if err := s.SetUserStripeAccount(
			accountID, stripeID, "ready", "US", "bank", "4242", false,
		); err != nil {
			t.Fatal(err)
		}
		if err := s.SetStripeAutoWithdraw(
			accountID, stripeID, true, now.Add(-2*time.Hour), slot,
		); err != nil {
			t.Fatal(err)
		}
	}

	first, err := s.ListUsersDueForStripeAutoWithdrawPage(now, time.Time{}, "", 2)
	if err != nil || len(first) != 2 {
		t.Fatalf("first page = %+v, err = %v", first, err)
	}
	second, err := s.ListUsersDueForStripeAutoWithdrawPage(
		now, *first[1].StripeAutoWithdrawNextAt, first[1].AccountID, 2,
	)
	if err != nil || len(second) != 1 || second[0].AccountID != "acct-page-c" {
		t.Fatalf("second page = %+v, err = %v", second, err)
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
	if err := s.SetStripeAutoWithdraw(user.AccountID, "acct_stripe", true, now.Add(-time.Hour), slot); err != nil {
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

	rows, err := s.ListStripeWithdrawalsBySourceStatusAfter(
		StripeWithdrawalSourceAutomatic, "pending",
		time.Now().Add(-time.Hour), time.Now(), 10,
	)
	if err != nil || len(rows) != 1 || rows[0].ID != "auto-pending" {
		t.Fatalf("rows = %+v, err = %v", rows, err)
	}
}

func TestMemoryStripeAutoWithdrawBindsExpectedDestination(t *testing.T) {
	s := NewMemory(Config{})
	user := &User{AccountID: "acct-auto-bind", PrivyUserID: "did:privy:auto-bind"}
	if err := s.CreateUser(user); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(user.AccountID, "acct_destination_b", "ready", "US", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	err := s.SetStripeAutoWithdraw(
		user.AccountID, "acct_stale_a", true, now, now.Add(time.Hour),
	)
	if !errors.Is(err, ErrAutoWithdrawNotAuthorized) {
		t.Fatalf("stale destination err = %v, want ErrAutoWithdrawNotAuthorized", err)
	}
	got, _ := s.GetUserByAccountID(user.AccountID)
	if got.StripeAutoWithdrawEnabled {
		t.Fatal("stale authorization enabled withdrawals for a replacement destination")
	}

	applied, err := s.SetUserStripeAccountIfCurrent(
		user.AccountID, "acct_stale_a", "", "", "", "", "", false,
	)
	if err != nil || applied {
		t.Fatalf("stale account CAS = %v, err = %v", applied, err)
	}
	got, _ = s.GetUserByAccountID(user.AccountID)
	if got.StripeAccountID != "acct_destination_b" {
		t.Fatalf("stale account CAS overwrote destination: %+v", got)
	}
}

func TestMemoryStripeWithdrawalAtomicFailureRefund(t *testing.T) {
	s := NewMemory(Config{})
	if err := s.CreditWithdrawable("acct-atomic-refund", 5_000_000, LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}
	wd := &StripeWithdrawal{
		ID: "wd-atomic-refund", AccountID: "acct-atomic-refund", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Source: StripeWithdrawalSourceAutomatic, Status: "pending",
	}
	if err := s.CreateStripeWithdrawalWithDebit(
		wd, LedgerStripePayout, "stripe_withdraw:"+wd.ID,
	); err != nil {
		t.Fatal(err)
	}
	refunded, err := s.FailStripeWithdrawalAndRefund(wd.ID, "transfer_create_failed")
	if err != nil || !refunded {
		t.Fatalf("refund = %v, err = %v", refunded, err)
	}
	stored, _ := s.GetStripeWithdrawal(wd.ID)
	if stored.Status != "failed" || !stored.Refunded ||
		s.GetWithdrawableBalance(wd.AccountID) != 5_000_000 {
		t.Fatalf("atomic refund state = %+v balance=%d", stored, s.GetWithdrawableBalance(wd.AccountID))
	}
	refunded, err = s.FailStripeWithdrawalAndRefund(wd.ID, "redelivery")
	if err != nil || !refunded || s.GetWithdrawableBalance(wd.AccountID) != 5_000_000 {
		t.Fatalf("idempotent refund = %v err=%v balance=%d",
			refunded, err, s.GetWithdrawableBalance(wd.AccountID))
	}
}

func TestMemoryStripeWithdrawalGuardedTransitionsAndLock(t *testing.T) {
	s := NewMemory(Config{})
	wd := &StripeWithdrawal{
		ID: "wd-guarded", AccountID: "acct-guarded", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Source: StripeWithdrawalSourceAutomatic, Status: "pending",
	}
	if err := s.CreateStripeWithdrawal(wd); err != nil {
		t.Fatal(err)
	}
	if applied, err := s.RecordStripeWithdrawalPendingFailure(wd.ID, "timeout", time.Now()); err != nil || !applied {
		t.Fatalf("pending failure = %v, err = %v", applied, err)
	}
	if applied, err := s.MarkStripeWithdrawalTransferred(wd.ID, "tr_guarded"); err != nil || !applied {
		t.Fatalf("mark transferred = %v, err = %v", applied, err)
	}
	if applied, err := s.RecordStripeWithdrawalPendingFailure(wd.ID, "stale timeout", time.Now()); err != nil || applied {
		t.Fatalf("stale failure = %v, err = %v", applied, err)
	}
	stored, _ := s.GetStripeWithdrawal(wd.ID)
	if stored.Status != "transferred" || stored.TransferID != "tr_guarded" ||
		stored.FailureReason != "" {
		t.Fatalf("stale worker overwrote success: %+v", stored)
	}

	acquired, release, err := s.TryLockStripeWithdrawal(wd.ID)
	if err != nil || !acquired {
		t.Fatalf("first lock = %v, err = %v", acquired, err)
	}
	if acquired, _, err := s.TryLockStripeWithdrawal(wd.ID); err != nil || acquired {
		t.Fatalf("second lock = %v, err = %v", acquired, err)
	}
	release()
	acquired, release, err = s.TryLockStripeWithdrawal(wd.ID)
	if err != nil || !acquired {
		t.Fatalf("lock after release = %v, err = %v", acquired, err)
	}
	release()
}

func TestMemoryAutomaticWithdrawalRetryEligibilityIsFair(t *testing.T) {
	s := NewMemory(Config{})
	now := time.Now().UTC()
	for i := 0; i < MaxStripeWithdrawalsByStatusLimit/10; i++ {
		created := now.Add(-time.Hour).Add(time.Duration(i) * time.Millisecond)
		retryAfter := now.Add(time.Hour)
		wd := &StripeWithdrawal{
			ID:        fmt.Sprintf("wd-deferred-%03d", i),
			AccountID: "acct-fair", StripeAccountID: "acct_stripe",
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "standard", Source: StripeWithdrawalSourceAutomatic,
			Status: "pending", CreatedAt: created, UpdatedAt: created,
			RetryAfter: &retryAfter,
		}
		if err := s.CreateStripeWithdrawal(wd); err != nil {
			t.Fatal(err)
		}
	}
	eligible := &StripeWithdrawal{
		ID: "wd-eligible-newer", AccountID: "acct-fair", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Source: StripeWithdrawalSourceAutomatic,
		Status: "pending", CreatedAt: now.Add(-time.Minute), UpdatedAt: now.Add(-time.Minute),
	}
	if err := s.CreateStripeWithdrawal(eligible); err != nil {
		t.Fatal(err)
	}

	rows, err := s.ListStripeWithdrawalsBySourceStatusAfter(
		StripeWithdrawalSourceAutomatic, "pending", now.Add(-2*time.Hour), now, 10,
	)
	if err != nil || len(rows) != 1 || rows[0].ID != eligible.ID {
		t.Fatalf("eligible rows = %+v, err = %v", rows, err)
	}
}

func TestMemoryReconciliationClaimsRotatePersistently(t *testing.T) {
	s := NewMemory(Config{})
	now := time.Now().UTC()
	created := now.Add(-72 * time.Hour)
	for i := 0; i < 33; i++ {
		if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
			ID:        fmt.Sprintf("wd-reconcile-%02d", i),
			AccountID: "acct-reconcile", StripeAccountID: "acct_stripe",
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "standard", Status: "transferred",
			CreatedAt: created.Add(time.Duration(i) * time.Millisecond),
		}); err != nil {
			t.Fatal(err)
		}
	}
	seen := map[string]bool{}
	for _, want := range []int{16, 16, 1} {
		rows, err := s.ClaimStripeWithdrawalsForReconciliation(
			"transferred", now.Add(-48*time.Hour), now, now.Add(time.Hour), 16,
		)
		if err != nil || len(rows) != want {
			t.Fatalf("claim len = %d, want %d, err = %v", len(rows), want, err)
		}
		for _, row := range rows {
			if seen[row.ID] {
				t.Fatalf("row %s was claimed twice before rotation completed", row.ID)
			}
			seen[row.ID] = true
		}
	}
	if len(seen) != 33 {
		t.Fatalf("claimed %d unique rows, want 33", len(seen))
	}
}

func TestMemoryReversalRefundAndSweepReopenAreGuarded(t *testing.T) {
	s := NewMemory(Config{})
	if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
		ID: "wd-reversal-paid", AccountID: "acct-reversal", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "paid", TransferID: "tr_paid",
	}); err != nil {
		t.Fatal(err)
	}
	if applied, err := s.RefundReversedStripeWithdrawal("wd-reversal-paid"); err != nil || applied {
		t.Fatalf("paid reversal refund = %v, err = %v", applied, err)
	}
	if balance := s.GetWithdrawableBalance("acct-reversal"); balance != 0 {
		t.Fatalf("paid reversal credited %d", balance)
	}

	if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
		ID: "wd-reversal-active", AccountID: "acct-reversal", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "instant", Status: "transferred", TransferID: "tr_active",
	}); err != nil {
		t.Fatal(err)
	}
	stale, _ := s.GetStripeWithdrawal("wd-reversal-active")
	if applied, err := s.RefundReversedStripeWithdrawal(stale.ID); err != nil || !applied {
		t.Fatalf("reversal refund = %v, err = %v", applied, err)
	}
	stale.PayoutID = "po_stale"
	if applied, err := s.UpdateStripeWithdrawalIfActive(stale); err != nil || applied {
		t.Fatalf("stale instant update = %v, err = %v", applied, err)
	}
	reversed, _ := s.GetStripeWithdrawal(stale.ID)
	if reversed.Status != "failed" || !reversed.Refunded || reversed.PayoutID != "" {
		t.Fatalf("stale instant update resurrected reversal: %+v", reversed)
	}

	if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
		ID: "wd-payout-aba", AccountID: "acct-reversal", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "instant", Status: "transferred", TransferID: "tr_aba",
	}); err != nil {
		t.Fatal(err)
	}
	firstAttempt, _ := s.GetStripeWithdrawal("wd-payout-aba")
	staleRetry := *firstAttempt
	firstAttempt.PayoutID = "po_aba"
	staleRetry.PayoutID = "po_aba"
	if applied, err := s.UpdateStripeWithdrawalIfActive(firstAttempt); err != nil || !applied {
		t.Fatalf("persist payout id = %v, err = %v", applied, err)
	}
	if applied, err := s.ReopenStripeWithdrawalAfterPayoutFailure(
		firstAttempt.ID, "payout failed", false,
	); err != nil || !applied {
		t.Fatalf("detach failed payout = %v, err = %v", applied, err)
	}
	if applied, err := s.UpdateStripeWithdrawalIfActive(&staleRetry); err != nil || applied {
		t.Fatalf("stale payout retry = %v, err = %v", applied, err)
	}
	afterRetry, _ := s.GetStripeWithdrawal(firstAttempt.ID)
	if afterRetry.PayoutID != "" || afterRetry.Status != "transferred" {
		t.Fatalf("stale retry reattached failed payout: %+v", afterRetry)
	}

	if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
		ID: "wd-transfer-recover", AccountID: "acct-reversal", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "instant", Status: "pending",
	}); err != nil {
		t.Fatal(err)
	}
	recoverTransfer, _ := s.GetStripeWithdrawal("wd-transfer-recover")
	recoverTransfer.TransferID = "tr_recovered"
	recoverTransfer.PayoutID = "po_recovered"
	recoverTransfer.Status = "transferred"
	if applied, err := s.UpdateStripeWithdrawalIfActive(recoverTransfer); err != nil || !applied {
		t.Fatalf("recover transfer+payout ids = %v, err = %v", applied, err)
	}
	if row, err := s.GetStripeWithdrawalByTransferID("tr_recovered"); err != nil || row.ID != recoverTransfer.ID {
		t.Fatalf("recovered transfer index row = %+v, err = %v", row, err)
	}

	if err := s.CreateStripeWithdrawal(&StripeWithdrawal{
		ID: "wd-sweep-guard", AccountID: "acct-reversal", StripeAccountID: "acct_stripe",
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "paid", TransferID: "tr_sweep",
		SweepPayoutID: "po_new",
	}); err != nil {
		t.Fatal(err)
	}
	if applied, err := s.ReopenStripeWithdrawalAfterSweepFailure(
		"wd-sweep-guard", "po_old", "old sweep failed",
	); err != nil || applied {
		t.Fatalf("stale sweep reopen = %v, err = %v", applied, err)
	}
	row, _ := s.GetStripeWithdrawal("wd-sweep-guard")
	if row.Status != "paid" || row.SweepPayoutID != "po_new" {
		t.Fatalf("stale sweep overwrote row: %+v", row)
	}
	if applied, err := s.ReopenStripeWithdrawalAfterSweepFailure(
		"wd-sweep-guard", "po_new", "new sweep failed",
	); err != nil || !applied {
		t.Fatalf("matching sweep reopen = %v, err = %v", applied, err)
	}
}
