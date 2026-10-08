package store_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// After the scrub no credit reaches the erased account: every credit path is
// refused, recorded for review, and reported to the caller as success. During
// the grace period credits still apply, because the erasure can be canceled.
func TestErasedAccountRefusesCredits(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			now := time.Now().UTC()
			req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)

			// Grace period: a credit applies.
			if err := s.Credit(a.AccountID, 1_000, store.LedgerRefund, "grace-refund"); err != nil {
				t.Fatal(err)
			}
			if s.GetBalance(a.AccountID) != 10_001_000 {
				t.Fatalf("balance during grace = %d", s.GetBalance(a.AccountID))
			}
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}

			// A payout bounce refund, a referral reward, a settlement refund and
			// a provider earning all arrive after the erasure.
			if ok, err := s.CreditWithdrawableOnce(a.AccountID, 2_000, store.LedgerRefund, "stripe_withdraw:wd-1"); err != nil || !ok {
				t.Fatalf("CreditWithdrawableOnce = %v, %v; the caller must see success", ok, err)
			}
			if err := s.CreditWithdrawable(a.AccountID, 3_000, store.LedgerReferralReward, "job-1"); err != nil {
				t.Fatal(err)
			}
			if err := s.Credit(a.AccountID, 4_000, store.LedgerStripeDeposit, "stripe:cs_late"); err != nil {
				t.Fatal(err)
			}
			if err := s.CreditProviderAccount(&store.ProviderEarning{AccountID: a.AccountID, ProviderID: a.ProviderID, JobID: erasurefixture.UniqueID("job"), Model: "m", AmountMicroUSD: 5_000}); err != nil {
				t.Fatal(err)
			}
			if b, w := s.GetBalance(a.AccountID), s.GetWithdrawableBalance(a.AccountID); b != 0 || w != 0 {
				t.Fatalf("erased balance = %d / %d; want 0 / 0", b, w)
			}
			var sum int64
			for _, e := range s.LedgerHistory(a.AccountID) {
				sum += e.AmountMicroUSD
			}
			if sum != 0 {
				t.Fatalf("ledger sum = %d; want 0", sum)
			}
			refused, err := s.ListErasureRefusedCredits(ctx, a.AccountID)
			if err != nil {
				t.Fatal(err)
			}
			got := map[string]int64{}
			for _, r := range refused {
				got[string(r.EntryType)+" "+r.Reference] += r.AmountMicroUSD
			}
			for key, want := range map[string]int64{
				"refund stripe_withdraw:wd-1": 2_000, "referral_reward job-1": 3_000, "stripe_deposit stripe:erased": 4_000,
			} {
				if got[key] != want {
					t.Errorf("refused %q = %d, want %d (all: %v)", key, got[key], want, got)
				}
			}
			var payout int64
			for _, r := range refused {
				if r.EntryType == store.LedgerPayout {
					payout += r.AmountMicroUSD
				}
			}
			if payout != 5_000 {
				t.Errorf("refused provider payout = %d, want 5000", payout)
			}
			// Another account is not affected.
			if err := s.Credit("acct-live-"+a.AccountID, 7, store.LedgerRefund, "r"); err != nil || s.GetBalance("acct-live-"+a.AccountID) != 7 {
				t.Fatalf("live account credit: %v, balance %d", err, s.GetBalance("acct-live-"+a.AccountID))
			}
		})
	}
}

// A replayed checkout.session.completed for a completed session of an
// erased account must be acknowledged (store.ErrCheckoutErased), not rejected as a
// conflict that Stripe retries for days.
func TestCompleteStripeCheckoutForErasedAccount(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a := erasurefixture.SeedAccount(t, s)
			repo, ok := store.As[store.StripeSettlementStore](s)
			if !ok {
				t.Fatal("no settlement store")
			}
			bs := erasurefixture.UniqueID("bs-done")
			if err := s.CreateBillingSession(&store.BillingSession{ID: bs, AccountID: a.AccountID, PaymentMethod: "stripe", AmountMicroUSD: 1_000_000, ExternalID: "cs_done_" + a.AccountID, Status: "pending", CreatedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			if _, err := repo.CompleteStripeCheckout(bs, "cs_done_"+a.AccountID, a.AccountID, 1_000_000); err != nil {
				t.Fatal(err)
			}
			now := time.Now().UTC()
			req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
			if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
				t.Fatal(err)
			}
			if _, err := repo.CompleteStripeCheckout(bs, "cs_done_"+a.AccountID, a.AccountID, 1_000_000); !errors.Is(err, store.ErrCheckoutErased) {
				t.Fatalf("replay after the scrub = %v; want store.ErrCheckoutErased", err)
			}
		})
	}
}
