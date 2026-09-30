package api

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCheckoutMigrationAcceptsBothSecretsAndCreditsOnce(t *testing.T) {
	s, st := stripePayoutsTestServer(t, true, nil)
	s.SetBilling(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{StripeSecretKey: "rk_new", StripeWebhookSecret: "whsec_new", StripeLegacyWebhookSecret: "whsec_old", StripeConnectSecretKey: "rk_old"}))
	if err := st.CreateBillingSession(&store.BillingSession{ID: "local-session", ExternalID: "cs_stripe", AccountID: "buyer", PaymentMethod: "stripe", AmountMicroUSD: 5_000_000, Status: "pending", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	payload := []byte(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_stripe","amount_total":500,"currency":"usd","payment_status":"paid","metadata":{"billing_session_id":"local-session","consumer_key":"buyer","app":"darkbloom"}}}}`)
	for _, secret := range []string{"whsec_old", "whsec_new", "whsec_old"} {
		w := httptest.NewRecorder()
		s.handleStripeWebhook(w, signedConnectRequest(t, payload, secret))
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", secret, w.Code, w.Body.String())
		}
	}
	if b, wd := st.GetBalanceWithWithdrawable("buyer"); b != 5_000_000 || wd != 0 {
		t.Fatalf("deposit %d/%d", b, wd)
	}
	w := httptest.NewRecorder()
	s.handleStripeWebhook(w, signedConnectRequest(t, payload, "whsec_wrong"))
	if w.Code != 400 {
		t.Fatal("wrong signature accepted")
	}
}

func TestConnectedAccountWebhookUsesSeparateSecretAndRequiresAccount(t *testing.T) {
	s, st := stripePayoutsTestServer(t, true, nil)
	s.SetBilling(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{StripeConnectSecretKey: "rk_old", StripeConnectWebhookSecret: "whsec_platform", StripeConnectAccountsWebhookSecret: "whsec_accounts"}))
	for _, tc := range []struct {
		account, secret string
		want            int
	}{
		{"acct_provider", "whsec_accounts", 200}, {"", "whsec_accounts", 400}, {"acct_provider", "whsec_platform", 400},
	} {
		payload := []byte(fmt.Sprintf(`{"type":"unused.event","account":%q,"data":{"object":{}}}`, tc.account))
		w := httptest.NewRecorder()
		s.handleStripeConnectAccountsWebhook(w, signedConnectRequest(t, payload, tc.secret))
		if w.Code != tc.want {
			t.Fatalf("got %d want %d", w.Code, tc.want)
		}
	}
}

func TestAmbiguousTransferThenRejectionNeverRefunds(t *testing.T) {
	remote := droppingStripe(t, "/v1/transfers", 1, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		_, _ = w.Write([]byte(`{"error":{"code":"permission_denied","message":"key access changed"}}`))
	})
	defer remote.Close()
	s, st := stripePayoutsTestServer(t, false, remote)
	u := readyUser(t, st, "ambiguous-rejected", "person@example.com", false)
	if err := st.CreditWithdrawable(u.AccountID, 10_000_000, store.LedgerPayout, "seed"); err != nil {
		t.Fatal(err)
	}
	w := globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"5.00"}`, s.handleStripeWithdraw)
	if w.Code != 502 {
		t.Fatal(w.Body.String())
	}
	rows, _ := st.ListStripeWithdrawals(u.AccountID, 10)
	if len(rows) != 1 || rows[0].Status != "pending" || rows[0].Refunded || st.GetBalance(u.AccountID) != 5_000_000 {
		t.Fatalf("unsafe refund: %+v", rows)
	}
}
