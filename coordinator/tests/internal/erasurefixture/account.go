// Package erasurefixture seeds accounts for the account erasure tests of the
// store contract, memory and PostgreSQL suites.
package erasurefixture

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Account is a test account with the data most erasure steps touch.
type Account struct {
	AccountID, PrivyID, Email, Stripe, RawKey, ProviderToken, ProviderID, SEKey, Checkout string
}

var idSeq atomic.Uint64

// UniqueID returns a process-unique identifier with the given prefix.
func UniqueID(prefix string) string {
	return fmt.Sprintf("%s-%d-%d", prefix, time.Now().UnixNano(), idSeq.Add(1))
}

// SeedAccount creates a user with a Stripe account, an API key, a provider
// token, a provider, a 10 USD balance (7 USD withdrawable) and a completed
// Checkout session.
func SeedAccount(t testing.TB, s store.Store) Account {
	t.Helper()
	a := Account{
		AccountID: UniqueID("acct-erase"), PrivyID: UniqueID("did:privy:erase"),
		Email: UniqueID("Erase") + "@Example.com", Stripe: UniqueID("acct_stripe"),
		ProviderToken: UniqueID("ptok"), ProviderID: UniqueID("prov"), SEKey: UniqueID("sekey"), Checkout: UniqueID("cs_test"),
	}
	if err := s.CreateUser(&store.User{AccountID: a.AccountID, PrivyUserID: a.PrivyID, Email: a.Email}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(a.AccountID, a.Stripe, "ready", "US", "bank", "4242", false); err != nil {
		t.Fatal(err)
	}
	raw, _, err := s.CreateAPIKey(a.AccountID, store.APIKeyCreate{Name: "laptop key"})
	if err != nil {
		t.Fatal(err)
	}
	a.RawKey = raw
	if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(a.ProviderToken), AccountID: a.AccountID, Label: "studio.local", Active: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertProvider(context.Background(), store.ProviderRecord{
		ID: a.ProviderID, Hardware: []byte(`{}`), Models: []byte(`[]`), Backend: "mlx",
		SerialNumber: UniqueID("SERIAL"), SEPublicKey: a.SEKey, AccountID: a.AccountID,
		Location: &store.ProviderLocation{City: "Lisbon"}, RegisteredAt: time.Now(), LastSeen: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(a.AccountID, 7_000_000, store.LedgerAdminReward, "admin_reward:note about the user"); err != nil {
		t.Fatal(err)
	}
	if err := s.Credit(a.AccountID, 3_000_000, store.LedgerStripeDeposit, "stripe:"+a.Checkout); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateBillingSession(&store.BillingSession{ID: UniqueID("bs"), AccountID: a.AccountID, PaymentMethod: "stripe", AmountMicroUSD: 3_000_000, ExternalID: a.Checkout, Status: "completed", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	return a
}

// PlanAndConfirm plans the erasure of a and confirms it at now with grace.
func PlanAndConfirm(t testing.TB, s store.Store, a Account, now time.Time, grace time.Duration) *store.ErasureRequest {
	t.Helper()
	ctx := context.Background()
	plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.SaveErasurePlan(ctx, a.AccountID, "admin_key", plan.ErasureCounts, nil, "token", now.Add(15*time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: a.AccountID, ConfirmToken: "token", Email: a.Email, Actor: "admin_key", Reason: "ticket 1", Now: now, Grace: grace})
	if err != nil {
		t.Fatal(err)
	}
	return req
}

// RowsFor returns the row count of rule in counts, or -1 when it is absent.
func RowsFor(counts []store.ErasureRowCount, rule string) int64 {
	for _, c := range counts {
		if c.Rule == rule {
			return c.Rows
		}
	}
	return -1
}
