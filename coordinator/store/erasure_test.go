package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// erasureAccount is a test account with the data most erasure steps touch.
type erasureAccount struct {
	AccountID, PrivyID, Email, Stripe, RawKey, ProviderToken, ProviderID, Checkout string
}

func seedErasureAccount(t *testing.T, s Store) erasureAccount {
	t.Helper()
	a := erasureAccount{
		AccountID: uniqueID("acct-erase"), PrivyID: uniqueID("did:privy:erase"),
		Email: uniqueID("Erase") + "@Example.com", Stripe: uniqueID("acct_stripe"),
		ProviderToken: uniqueID("ptok"), ProviderID: uniqueID("prov"), Checkout: uniqueID("cs_test"),
	}
	if err := s.CreateUser(&User{AccountID: a.AccountID, PrivyUserID: a.PrivyID, Email: a.Email}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(a.AccountID, a.Stripe, "ready", "US", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}
	raw, _, err := s.CreateAPIKey(a.AccountID, APIKeyCreate{Name: "laptop key"})
	if err != nil {
		t.Fatal(err)
	}
	a.RawKey = raw
	if err := s.CreateProviderToken(&ProviderToken{TokenHash: hashKey(a.ProviderToken), AccountID: a.AccountID, Label: "studio.local", Active: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertProvider(context.Background(), ProviderRecord{
		ID: a.ProviderID, Hardware: []byte(`{}`), Models: []byte(`[]`), Backend: "mlx",
		SerialNumber: uniqueID("SERIAL"), SEPublicKey: uniqueID("sekey"), AccountID: a.AccountID,
		Location: &ProviderLocation{City: "Lisbon"}, RegisteredAt: time.Now(), LastSeen: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(a.AccountID, 7_000_000, LedgerAdminReward, "admin_reward:note about the user"); err != nil {
		t.Fatal(err)
	}
	if err := s.Credit(a.AccountID, 3_000_000, LedgerStripeDeposit, "stripe:"+a.Checkout); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateBillingSession(&BillingSession{ID: uniqueID("bs"), AccountID: a.AccountID, PaymentMethod: "stripe", AmountMicroUSD: 3_000_000, ExternalID: a.Checkout, Status: "completed", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return a
}

func planAndConfirm(t *testing.T, s Store, a erasureAccount, now time.Time, grace time.Duration) *ErasureRequest {
	t.Helper()
	ctx := context.Background()
	plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(15*time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Actor: "admin_key", Reason: "ticket 1", Now: now, Grace: grace})
	if err != nil {
		t.Fatal(err)
	}
	return req
}

func rowsFor(counts []ErasureRowCount, rule string) int64 {
	for _, c := range counts {
		if c.Rule == rule {
			return c.Rows
		}
	}
	return -1
}

func TestAccountErasureLifecycle(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := seedErasureAccount(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)

			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			if plan.Email != a.Email || plan.BalanceMicroUSD != 10_000_000 || plan.WithdrawableMicroUSD != 7_000_000 {
				t.Fatalf("plan = %+v", plan)
			}
			for rule, want := range map[string]int64{"users": 1, "api_keys": 1, "provider_tokens": 1, "providers": 1, "billing_sessions": 1, "ledger_entries_stripe_reference": 1, "ledger_entries_admin_note": 1} {
				if got := rowsFor(plan.Rows, rule); got != want {
					t.Errorf("plan rows %s = %d, want %d", rule, got, want)
				}
			}
			if len(plan.StripeObjects) != 2 || plan.StripeObjectCounts[ErasureTargetCheckoutSessions] != 1 {
				t.Fatalf("stripe objects = %+v / %+v", plan.StripeObjects, plan.StripeObjectCounts)
			}
			if u, err := s.GetUserByAccountID(a.AccountID); err != nil || u.Email != a.Email {
				t.Fatalf("plan changed the user: %+v %v", u, err)
			}

			// The confirm call checks the token, its expiry and the email.
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, ErrErasureConfirmToken) {
				t.Fatalf("confirm without a plan: %v", err)
			}
			if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, []string{"0xabc"}, "token", now.Add(15*time.Minute)); err != nil {
				t.Fatal(err)
			}
			// The wallet list is bound to the plan.
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, WalletAddresses: []string{"0xabc", "0xother"}, Now: now}); !errors.Is(err, ErrErasureWalletMismatch) {
				t.Fatalf("other wallets: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, ErrErasureWalletMismatch) {
				t.Fatalf("no wallets: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "wrong", Email: a.Email, Now: now}); !errors.Is(err, ErrErasureConfirmToken) {
				t.Fatalf("wrong token: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now.Add(16 * time.Minute)}); !errors.Is(err, ErrErasureConfirmToken) {
				t.Fatalf("expired token: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: "someone@else", Now: now}); !errors.Is(err, ErrErasureEmailMismatch) {
				t.Fatalf("wrong email: %v", err)
			}
			req, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: "  " + a.Email + " ", Actor: "admin_key", Reason: "ticket 1", WalletAddresses: []string{"0xabc", "0xabc", " "}, Now: now, Grace: time.Hour})
			if err != nil {
				t.Fatal(err)
			}
			if req.State != ErasurePending || req.ScrubAfter == nil || !req.ScrubAfter.Equal(now.Add(time.Hour)) || req.WalletAddressCount != 1 {
				t.Fatalf("pending request = %+v", req)
			}

			// Soft deleted: hidden, keys and tokens revoked, login refused.
			if _, err := s.GetUserByAccountID(a.AccountID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("user still live: %v", err)
			}
			if _, err := s.AuthenticateKey(a.RawKey); err == nil {
				t.Fatal("API key still authenticates")
			}
			if _, err := s.GetProviderToken(a.ProviderToken); err == nil {
				t.Fatal("provider token still valid")
			}
			if pending, err := s.PrivyUserPendingErasure(ctx, a.PrivyID); err != nil || !pending {
				t.Fatalf("PrivyUserPendingErasure = %v, %v", pending, err)
			}
			if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "t2", now.Add(time.Minute)); !errors.Is(err, ErrNotFound) && !errors.Is(err, ErrErasureConflict) {
				t.Fatalf("plan while pending: %v", err)
			}

			// Cancel restores the user; the key stays revoked.
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(2*time.Hour)); !errors.Is(err, ErrErasureConflict) {
				t.Fatalf("cancel after grace: %v", err)
			}
			canceled, err := s.CancelAccountErasure(ctx, a.AccountID, "account:admin", now.Add(time.Minute))
			if err != nil || canceled.State != ErasureCanceled || canceled.CanceledBy != "account:admin" {
				t.Fatalf("cancel = %+v, %v", canceled, err)
			}
			if u, err := s.GetUserByAccountID(a.AccountID); err != nil || u.Email != a.Email {
				t.Fatalf("user after cancel = %+v, %v", u, err)
			}
			if _, err := s.AuthenticateKey(a.RawKey); err == nil {
				t.Fatal("cancel revived the API key")
			}
			if pending, _ := s.PrivyUserPendingErasure(ctx, a.PrivyID); pending {
				t.Fatal("canceled account still pending")
			}

			// Confirm again and scrub.
			req = planAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, "missing", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("scrub of a missing request: %v", err)
			}
			res, err := s.ScrubAccount(ctx, req.ID, now)
			if err != nil {
				t.Fatal(err)
			}
			if res.Request.State != ErasureErased || res.Request.ErasedAt == nil || len(res.SEKeys) != 1 || len(res.ProviderIDs) != 1 {
				t.Fatalf("scrub result = %+v", res)
			}
			applied := res.Request.Summary.Applied
			if applied == nil || res.Request.Summary.Planned == nil || applied.BalanceMicroUSD != 10_000_000 || rowsFor(applied.Rows, "providers") != 1 {
				t.Fatalf("summary = %+v", res.Request.Summary)
			}
			if _, err := s.ScrubAccount(ctx, req.ID, now); !errors.Is(err, ErrErasureConflict) {
				t.Fatalf("second scrub: %v", err)
			}

			// The ledger still sums to the balance, which is zero.
			if b, w := s.GetBalance(a.AccountID), s.GetWithdrawableBalance(a.AccountID); b != 0 || w != 0 {
				t.Fatalf("balance after scrub = %d / %d", b, w)
			}
			var sum int64
			var forfeit bool
			for _, e := range s.LedgerHistory(a.AccountID) {
				sum += e.AmountMicroUSD
				forfeit = forfeit || (e.Type == LedgerErasureForfeit && e.AmountMicroUSD == -10_000_000)
				if e.Reference == "stripe:"+a.Checkout || e.Reference == "admin_reward:note about the user" {
					t.Errorf("ledger reference kept: %q", e.Reference)
				}
			}
			if sum != 0 || !forfeit {
				t.Fatalf("ledger sum = %d, forfeit entry = %v", sum, forfeit)
			}

			got, outbox, err := s.GetAccountErasure(ctx, a.AccountID)
			if err != nil || got.ID != req.ID {
				t.Fatalf("GetAccountErasure = %+v, %v", got, err)
			}
			targets := map[ErasureTarget]string{}
			for _, o := range outbox {
				if o.State != ErasureOutboxPending {
					t.Errorf("outbox %s state %s", o.Target, o.State)
				}
				targets[o.Target] = o.ExternalID
			}
			if targets[ErasureTargetStripeAccount] != a.Stripe || targets[ErasureTargetCheckoutSessions] != a.Checkout || len(targets) != 3 {
				t.Fatalf("outbox targets = %+v", targets)
			}
			if _, ok := targets[ErasureTargetErasureLog]; !ok {
				t.Fatal("no erasure_log outbox row")
			}

			// The old Privy ID is free: a new login makes a fresh account.
			if pending, _ := s.PrivyUserPendingErasure(ctx, a.PrivyID); pending {
				t.Fatal("erased account still blocks its Privy ID")
			}
			if _, err := s.GetUserByPrivyID(a.PrivyID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("Privy lookup after scrub: %v", err)
			}
			if err := s.CreateUser(&User{AccountID: uniqueID("acct-new"), PrivyUserID: a.PrivyID}); err != nil {
				t.Fatalf("re-signup: %v", err)
			}
		})
	}
}

func TestAccountErasureRefusesOpenWithdrawal(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := seedErasureAccount(t, s)
			now := time.Now().UTC()
			wd := &StripeWithdrawal{ID: uniqueID("wd"), AccountID: a.AccountID, StripeAccountID: a.Stripe, AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000, Method: "standard", Status: "pending"}
			if err := s.CreateStripeWithdrawalWithDebit(wd, LedgerStripePayout, "stripe_withdraw:"+wd.ID); err != nil {
				t.Fatal(err)
			}
			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil || plan.OpenWithdrawals != 1 {
				t.Fatalf("plan open withdrawals = %+v, %v", plan, err)
			}
			if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, ErrErasureOpenWithdrawal) {
				t.Fatalf("request with an open withdrawal: %v", err)
			}
			if _, err := s.GetUserByAccountID(a.AccountID); err != nil {
				t.Fatalf("refused request changed the user: %v", err)
			}

			// A recently paid withdrawal can still bounce and refund the
			// ledger, so it counts as open.
			wd.Status = "paid"
			if err := s.UpdateStripeWithdrawal(wd); err != nil {
				t.Fatal(err)
			}
			if _, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, ErrErasureOpenWithdrawal) {
				t.Fatalf("request with a recently paid withdrawal: %v", err)
			}
			ageWithdrawal(t, s, wd.ID, now.Add(-stripePayoutBounceWindow-time.Hour))

			// A withdrawal that opens during the grace period blocks the scrub.
			req, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now, Grace: time.Hour})
			if err != nil {
				t.Fatal(err)
			}
			wd.Status = "transferred"
			if err := s.UpdateStripeWithdrawal(wd); err != nil {
				t.Fatal(err)
			}
			if _, err := s.ScrubAccount(ctx, req.ID, now); !errors.Is(err, ErrErasureOpenWithdrawal) {
				t.Fatalf("scrub with an open withdrawal: %v", err)
			}
			if err := s.RecordAccountErasureFailure(ctx, req.ID, ErrErasureOpenWithdrawal.Error()); err != nil {
				t.Fatal(err)
			}
			got, _, err := s.GetAccountErasure(ctx, a.AccountID)
			if err != nil || got.State != ErasurePending || got.LastError == "" {
				t.Fatalf("request after refused scrub = %+v, %v", got, err)
			}
		})
	}
}

func TestLeaseDueAccountErasures(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC()
			due := planAndConfirm(t, s, seedErasureAccount(t, s), now.Add(-2*time.Hour), time.Hour)
			planAndConfirm(t, s, seedErasureAccount(t, s), now, time.Hour) // not due yet

			ids, err := s.LeaseDueAccountErasures(ctx, now, time.Hour, 10)
			if err != nil || len(ids) != 1 || ids[0] != due.ID {
				t.Fatalf("lease = %v, %v; want [%s]", ids, err, due.ID)
			}
			if ids, err := s.LeaseDueAccountErasures(ctx, now, time.Hour, 10); err != nil || len(ids) != 0 {
				t.Fatalf("second lease = %v, %v; want none while leased", ids, err)
			}
			// After the lease ends both are due.
			if ids, err := s.LeaseDueAccountErasures(ctx, now.Add(61*time.Minute), time.Hour, 10); err != nil || len(ids) != 2 {
				t.Fatalf("lease after expiry = %v, %v", ids, err)
			}
		})
	}
}

func TestSoftDeletedProviderIgnoresLatePersist(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := seedErasureAccount(t, s)
			planAndConfirm(t, s, a, time.Now().UTC(), time.Hour)
			if err := s.UpsertProvider(ctx, ProviderRecord{
				ID: a.ProviderID, Hardware: []byte(`{}`), Models: []byte(`[]`), Backend: "mlx",
				SerialNumber: "LATE-SERIAL", AccountID: a.AccountID, RegisteredAt: time.Now(), LastSeen: time.Now(),
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", time.Now().UTC()); err != nil {
				t.Fatal(err)
			}
			rec, err := s.GetProviderRecord(ctx, a.ProviderID)
			if err != nil {
				t.Fatal(err)
			}
			if rec.SerialNumber == "LATE-SERIAL" {
				t.Fatal("a persist after the soft delete rewrote the provider row")
			}
		})
	}
}

func TestMemoryErasureRulesCoverRuleTable(t *testing.T) {
	names := map[string]bool{}
	for _, r := range erasureRules {
		if names[r.Name] {
			t.Errorf("rule %q listed twice", r.Name)
		}
		names[r.Name] = true
		if _, ok := memoryErasureRules[r.Name]; !ok {
			t.Errorf("rule %q has no memory form", r.Name)
		}
		if r.Delete == (len(r.Columns) > 0) {
			t.Errorf("rule %q: a delete rule lists no columns and an update rule lists some", r.Name)
		}
	}
	for name := range memoryErasureRules {
		if !names[name] {
			t.Errorf("memory rule %q is not in erasureRules", name)
		}
	}
}

// The erasure steps write users, so CachedStore must drop cached users;
// otherwise a soft-deleted account keeps authenticating for up to UserTTL.
func TestCachedStoreInvalidatesUsersOnErasure(t *testing.T) {
	ctx := context.Background()
	c := NewCached(NewMemory(Config{}), CacheConfig{UserTTL: time.Hour, NegativeTTL: time.Hour})
	a := seedErasureAccount(t, c)
	if _, err := c.GetUserByAccountID(a.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetUserByPrivyID(a.PrivyID); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	planAndConfirm(t, c, a, now, time.Hour)
	if _, err := c.GetUserByAccountID(a.AccountID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cached user after soft delete: %v", err)
	}
	if _, err := c.GetUserByPrivyID(a.PrivyID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cached Privy user after soft delete: %v", err)
	}
	if _, err := c.CancelAccountErasure(ctx, a.AccountID, "admin_key", now); err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetUserByAccountID(a.AccountID); err != nil {
		t.Fatalf("cached negative entry after cancel: %v", err)
	}
	req := planAndConfirm(t, c, a, now, 0)
	if _, err := c.GetUserByAccountID(a.AccountID); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := c.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	if c.Stats().Users.Invalidations < 4 {
		t.Fatalf("invalidations = %d; want one per erasure write", c.Stats().Users.Invalidations)
	}
}

// ageWithdrawal moves a withdrawal's updated_at back, past the bounce window.
func ageWithdrawal(t *testing.T, s Store, id string, at time.Time) {
	t.Helper()
	switch st := s.(type) {
	case *PostgresStore:
		if _, err := st.pool.Exec(context.Background(), `UPDATE stripe_withdrawals SET updated_at = $2 WHERE id = $1`, id, at); err != nil {
			t.Fatal(err)
		}
	case *MemoryStore:
		st.mu.Lock()
		st.stripeWithdrawalsByID[id].UpdatedAt = at
		st.mu.Unlock()
	default:
		t.Fatalf("unsupported store %T", s)
	}
}
