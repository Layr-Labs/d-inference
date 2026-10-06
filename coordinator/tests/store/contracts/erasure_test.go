package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestAccountErasureLifecycle(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)

			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			if plan.Email != a.Email || plan.BalanceMicroUSD != 10_000_000 || plan.WithdrawableMicroUSD != 7_000_000 {
				t.Fatalf("plan = %+v", plan)
			}
			for rule, want := range map[string]int64{"users": 1, "api_keys": 1, "provider_tokens": 1, "providers": 1, "billing_sessions": 1, "ledger_entries_stripe_reference": 1, "ledger_entries_admin_note": 1} {
				if got := erasurefixture.RowsFor(plan.Rows, rule); got != want {
					t.Errorf("plan rows %s = %d, want %d", rule, got, want)
				}
			}
			if len(plan.StripeObjects) != 2 || plan.StripeObjectCounts[store.ErasureTargetCheckoutSessions] != 1 {
				t.Fatalf("stripe objects = %+v / %+v", plan.StripeObjects, plan.StripeObjectCounts)
			}
			if u, err := s.GetUserByAccountID(a.AccountID); err != nil || u.Email != a.Email {
				t.Fatalf("plan changed the user: %+v %v", u, err)
			}

			// The confirm call checks the token, its expiry and the email.
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, store.ErrErasureConfirmToken) {
				t.Fatalf("confirm without a plan: %v", err)
			}
			if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, []string{"0xabc"}, "token", now.Add(15*time.Minute)); err != nil {
				t.Fatal(err)
			}
			// The wallet list is bound to the plan.
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, WalletAddresses: []string{"0xabc", "0xother"}, Now: now}); !errors.Is(err, store.ErrErasureWalletMismatch) {
				t.Fatalf("other wallets: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, store.ErrErasureWalletMismatch) {
				t.Fatalf("no wallets: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "wrong", Email: a.Email, Now: now}); !errors.Is(err, store.ErrErasureConfirmToken) {
				t.Fatalf("wrong token: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now.Add(16 * time.Minute)}); !errors.Is(err, store.ErrErasureConfirmToken) {
				t.Fatalf("expired token: %v", err)
			}
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: "someone@else", Now: now}); !errors.Is(err, store.ErrErasureEmailMismatch) {
				t.Fatalf("wrong email: %v", err)
			}
			req, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: "  " + a.Email + " ", Actor: "admin_key", Reason: "ticket 1", WalletAddresses: []string{"0xabc", "0xabc", " "}, Now: now, Grace: time.Hour})
			if err != nil {
				t.Fatal(err)
			}
			if req.State != store.ErasurePending || req.ScrubAfter == nil || !req.ScrubAfter.Equal(now.Add(time.Hour)) || req.WalletAddressCount != 1 {
				t.Fatalf("pending request = %+v", req)
			}

			// Soft deleted: hidden, keys and tokens revoked, login refused.
			if _, err := s.GetUserByAccountID(a.AccountID); !errors.Is(err, store.ErrNotFound) {
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
			if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "t2", now.Add(time.Minute)); !errors.Is(err, store.ErrNotFound) && !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("plan while pending: %v", err)
			}

			// Cancel restores the user; the key stays revoked.
			if _, err := s.CancelAccountErasure(ctx, a.AccountID, "admin_key", now.Add(2*time.Hour)); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("cancel after grace: %v", err)
			}
			canceled, err := s.CancelAccountErasure(ctx, a.AccountID, "account:admin", now.Add(time.Minute))
			if err != nil || canceled.State != store.ErasureCanceled || canceled.CanceledBy != "account:admin" {
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
			req = erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, "missing", now); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("scrub of a missing request: %v", err)
			}
			res, err := s.ScrubAccount(ctx, req.ID, now)
			if err != nil {
				t.Fatal(err)
			}
			if res.Request.State != store.ErasureErased || res.Request.ErasedAt == nil || len(res.SEKeys) != 1 || len(res.ProviderIDs) != 1 {
				t.Fatalf("scrub result = %+v", res)
			}
			applied := res.Request.Summary.Applied
			if applied == nil || res.Request.Summary.Planned == nil || applied.BalanceMicroUSD != 10_000_000 || erasurefixture.RowsFor(applied.Rows, "providers") != 1 {
				t.Fatalf("summary = %+v", res.Request.Summary)
			}
			if _, err := s.ScrubAccount(ctx, req.ID, now); !errors.Is(err, store.ErrErasureConflict) {
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
				forfeit = forfeit || (e.Type == store.LedgerErasureForfeit && e.AmountMicroUSD == -10_000_000)
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
			targets := map[store.ErasureTarget]string{}
			for _, o := range outbox {
				if o.State != store.ErasureOutboxPending {
					t.Errorf("outbox %s state %s", o.Target, o.State)
				}
				targets[o.Target] = o.ExternalID
			}
			if targets[store.ErasureTargetStripeAccount] != a.Stripe || targets[store.ErasureTargetCheckoutSessions] != a.Checkout || len(targets) != 3 {
				t.Fatalf("outbox targets = %+v", targets)
			}
			if _, ok := targets[store.ErasureTargetErasureLog]; !ok {
				t.Fatal("no erasure_log outbox row")
			}

			// The old Privy ID is free: a new login makes a fresh account.
			if pending, _ := s.PrivyUserPendingErasure(ctx, a.PrivyID); pending {
				t.Fatal("erased account still blocks its Privy ID")
			}
			if _, err := s.GetUserByPrivyID(a.PrivyID); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("Privy lookup after scrub: %v", err)
			}
			if err := s.CreateUser(&store.User{AccountID: erasurefixture.UniqueID("acct-new"), PrivyUserID: a.PrivyID}); err != nil {
				t.Fatalf("re-signup: %v", err)
			}
		})
	}
}

func TestAccountErasureRefusesOpenWithdrawal(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC()
			wd := &store.StripeWithdrawal{ID: erasurefixture.UniqueID("wd"), AccountID: a.AccountID, StripeAccountID: a.Stripe, AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000, Method: "standard", Status: "pending"}
			if err := s.CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, "stripe_withdraw:"+wd.ID); err != nil {
				t.Fatal(err)
			}
			plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
			if err != nil || plan.OpenWithdrawals != 1 {
				t.Fatalf("plan open withdrawals = %+v, %v", plan, err)
			}
			if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, store.ErrErasureOpenWithdrawal) {
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
			if _, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: now}); !errors.Is(err, store.ErrErasureOpenWithdrawal) {
				t.Fatalf("request with a recently paid withdrawal: %v", err)
			}
			// Past the bounce window the paid withdrawal is closed.
			later := now.Add(erasure.StripePayoutBounceWindow + time.Hour)
			if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", later.Add(time.Minute)); err != nil {
				t.Fatal(err)
			}

			// A withdrawal that opens during the grace period blocks the scrub.
			req, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Now: later, Grace: time.Hour})
			if err != nil {
				t.Fatal(err)
			}
			wd.Status = "transferred"
			if err := s.UpdateStripeWithdrawal(wd); err != nil {
				t.Fatal(err)
			}
			if _, err := s.ScrubAccount(ctx, req.ID, later); !errors.Is(err, store.ErrErasureOpenWithdrawal) {
				t.Fatalf("scrub with an open withdrawal: %v", err)
			}
			if err := s.RecordAccountErasureFailure(ctx, req.ID, store.ErrErasureOpenWithdrawal.Error()); err != nil {
				t.Fatal(err)
			}
			got, _, err := s.GetAccountErasure(ctx, a.AccountID)
			if err != nil || got.State != store.ErasurePending || got.LastError == "" {
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
			due := erasurefixture.PlanAndConfirm(t, s, erasurefixture.SeedAccount(t, s), now.Add(-2*time.Hour), time.Hour)
			erasurefixture.PlanAndConfirm(t, s, erasurefixture.SeedAccount(t, s), now, time.Hour) // not due yet

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
			a := erasurefixture.SeedAccount(t, s)
			erasurefixture.PlanAndConfirm(t, s, a, time.Now().UTC(), time.Hour)
			if err := s.UpsertProvider(ctx, store.ProviderRecord{
				ID: a.ProviderID, Hardware: []byte(`{}`), Models: []byte(`[]`), Backend: "mlx",
				SerialNumber: "LATE-SERIAL", AccountID: a.AccountID, RegisteredAt: time.Now(), LastSeen: time.Now(),
			}); !errors.Is(err, store.ErrErasureConflict) {
				t.Fatalf("late provider persist: %v", err)
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

// The erasure steps write users, so CachedStore must drop cached users;
// otherwise a soft-deleted account keeps authenticating for up to UserTTL.
func TestCachedStoreInvalidatesUsersOnErasure(t *testing.T) {
	ctx := context.Background()
	c := store.NewCached(memory.NewMemory(store.Config{}), store.CacheConfig{UserTTL: time.Hour, NegativeTTL: time.Hour})
	a := erasurefixture.SeedAccount(t, c)
	if _, err := c.GetUserByAccountID(a.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetUserByPrivyID(a.PrivyID); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	erasurefixture.PlanAndConfirm(t, c, a, now, time.Hour)
	if _, err := c.GetUserByAccountID(a.AccountID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("cached user after soft delete: %v", err)
	}
	if _, err := c.GetUserByPrivyID(a.PrivyID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("cached Privy user after soft delete: %v", err)
	}
	if _, err := c.CancelAccountErasure(ctx, a.AccountID, "admin_key", now); err != nil {
		t.Fatal(err)
	}
	if _, err := c.GetUserByAccountID(a.AccountID); err != nil {
		t.Fatalf("cached negative entry after cancel: %v", err)
	}
	req := erasurefixture.PlanAndConfirm(t, c, a, now, 0)
	if _, err := c.GetUserByAccountID(a.AccountID); !errors.Is(err, store.ErrNotFound) {
		t.Fatal(err)
	}
	if _, err := c.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	if c.Stats().Users.Invalidations < 4 {
		t.Fatalf("invalidations = %d; want one per erasure write", c.Stats().Users.Invalidations)
	}
}

// Every backend runs the whole rule table, in order. A rule without a
// backend form fails the plan.
func TestErasurePlanRunsEveryRuleInOrder(t *testing.T) {
	names := map[string]bool{}
	for _, r := range erasure.Rules {
		if names[r.Name] {
			t.Errorf("rule %q listed twice", r.Name)
		}
		names[r.Name] = true
		if r.Delete == (len(r.Columns) > 0) {
			t.Errorf("rule %q: a delete rule lists no columns and an update rule lists some", r.Name)
		}
	}
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			a := erasurefixture.SeedAccount(t, s)
			plan, err := s.PlanAccountErasure(context.Background(), a.AccountID, nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(plan.Rows) != len(erasure.Rules) {
				t.Fatalf("plan has %d rows; the rule table has %d", len(plan.Rows), len(erasure.Rules))
			}
			for i, r := range erasure.Rules {
				if plan.Rows[i].Rule != r.Name || plan.Rows[i].Table != r.Table {
					t.Errorf("plan row %d = %s on %s; want %s on %s", i, plan.Rows[i].Rule, plan.Rows[i].Table, r.Name, r.Table)
				}
			}
		})
	}
}
