package billing_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
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
