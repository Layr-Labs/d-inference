package billing_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

// A Checkout Session that completes after the scrub is acknowledged, not
// retried, and credits nothing.
func TestCheckoutWebhookAcknowledgesErasedSession(t *testing.T) {
	s, st := stripePayoutsTestServer(t, true, nil)
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{StripeSecretKey: "rk_new", StripeWebhookSecret: "whsec_test"}))
	account := "acct-checkout-erased"
	if err := st.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:checkout", Email: "c@example.com"}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateBillingSession(&store.BillingSession{ID: "late-session", ExternalID: "cs_late", AccountID: account, PaymentMethod: "stripe", AmountMicroUSD: 5_000_000, Status: "pending", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	now := time.Now()
	plan, err := st.PlanAccountErasure(ctx, account, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.SaveErasurePlan(ctx, account, "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := st.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: account, ConfirmToken: "token", Email: "c@example.com", Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	payload := []byte(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_late","amount_total":500,"currency":"usd","payment_status":"paid","metadata":{"billing_session_id":"late-session","consumer_key":"` + account + `","app":"darkbloom"}}}}`)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, signedStripeRequest(t, payload, "whsec_test", "/v1/billing/stripe/webhook"))
	if w.Code != http.StatusOK {
		t.Fatalf("late checkout webhook = %d %s", w.Code, w.Body.String())
	}
	if st.GetBalance(account) != 0 {
		t.Fatalf("late checkout credited %d", st.GetBalance(account))
	}
}

func TestCheckoutWebhookIgnoresErasedReferrerMetadata(t *testing.T) {
	s, st := stripePayoutsTestServer(t, true, nil)
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{StripeSecretKey: "rk_new", StripeWebhookSecret: "whsec_test"}))
	a, b := erasurefixture.SeedAccount(t, st), erasurefixture.SeedAccount(t, st)
	if err := st.CreateReferrer(a.AccountID, "PERSONAL-CODE"); err != nil {
		t.Fatal(err)
	}
	// A historical Stripe session retains its original metadata; local scrub owns
	// the authoritative attribution. The live buyer's payment still settles.
	session := &store.BillingSession{ID: "live-buyer-session", AccountID: b.AccountID, PaymentMethod: "stripe", ExternalID: "cs_live_buyer", AmountMicroUSD: 5_000_000, Status: "pending", ReferralCode: "PERSONAL-CODE", ReferrerAccountID: a.AccountID}
	if err := st.CreateBillingSession(session); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, st, a, now, 0)
	if _, err := st.ScrubAccount(context.Background(), req.ID, now); err != nil {
		t.Fatal(err)
	}
	// Reusing the old public code must not redirect a delayed webhook's credit.
	if err := st.CreateReferrer("different-promoter", "PERSONAL-CODE"); err != nil {
		t.Fatal(err)
	}
	payload := []byte(fmt.Sprintf(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_live_buyer","amount_total":500,"currency":"usd","payment_status":"paid","metadata":{"billing_session_id":"live-buyer-session","consumer_key":%q,"referral_code":"PERSONAL-CODE","app":"darkbloom"}}}}`, b.AccountID))
	for range 2 {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, signedStripeRequest(t, payload, "whsec_test", "/v1/billing/stripe/webhook"))
		if w.Code != http.StatusOK {
			t.Fatalf("webhook = %d %s", w.Code, w.Body.String())
		}
	}
	if st.GetBalance(b.AccountID) != 15_000_000 {
		t.Fatal("live buyer payment lost or duplicated")
	}
	code, err := st.GetReferrerForAccount(b.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if code == "PERSONAL-CODE" {
		t.Fatal("historical metadata restored the erased personal referral code")
	}
}
