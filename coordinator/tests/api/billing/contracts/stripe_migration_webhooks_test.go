package billing_test

import (
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type checkoutReferralRetryStore struct {
	*memory.MemoryStore
	failReferral bool
}

func (s *checkoutReferralRetryStore) RecordReferral(code, account string) error {
	if s.failReferral {
		return errors.New("temporary referral persistence failure")
	}
	return s.MemoryStore.RecordReferral(code, account)
}

func TestCheckoutReferralRetriesWithoutRecreditingDeposit(t *testing.T) {
	s, mem := stripePayoutsTestServer(t, true, nil)
	st := &checkoutReferralRetryStore{MemoryStore: mem, failReferral: true}
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{StripeSecretKey: "rk_new", StripeWebhookSecret: "whsec_test"}))
	if err := mem.CreateReferrer("promoter", "REFER"); err != nil {
		t.Fatal(err)
	}
	if err := mem.CreateBillingSession(&store.BillingSession{ID: "referral-session", ExternalID: "cs_referral", AccountID: "buyer", PaymentMethod: "stripe", AmountMicroUSD: 5_000_000, Status: "pending", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	payload := []byte(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_referral","amount_total":500,"currency":"usd","payment_status":"paid","metadata":{"billing_session_id":"referral-session","consumer_key":"buyer","referral_code":"REFER","app":"darkbloom"}}}}`)
	for i, want := range []int{500, 200, 200} {
		st.failReferral = i == 0
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, signedStripeRequest(t, payload, "whsec_test", "/v1/billing/stripe/webhook"))
		if w.Code != want {
			t.Fatalf("attempt %d: %d %s", i, w.Code, w.Body.String())
		}
		if mem.GetBalance("buyer") != 5_000_000 {
			t.Fatal("referral retry duplicated deposit")
		}
	}
	if code, err := mem.GetReferrerForAccount("buyer"); err != nil || code != "REFER" {
		t.Fatalf("attribution: %s %v", code, err)
	}
}

func TestCheckoutAcknowledgesPermanentReferralErrors(t *testing.T) {
	for _, kind := range []string{"self", "missing", "already_assigned"} {
		t.Run(kind, func(t *testing.T) {
			s, st := stripePayoutsTestServer(t, true, nil)
			s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{StripeSecretKey: "rk_new", StripeWebhookSecret: "whsec_test"}))
			if kind == "self" {
				if err := st.CreateReferrer("buyer", "REFER"); err != nil {
					t.Fatal(err)
				}
			}
			if kind == "already_assigned" {
				if err := st.CreateReferrer("first", "FIRST"); err != nil {
					t.Fatal(err)
				}
				if err := st.CreateReferrer("later", "REFER"); err != nil {
					t.Fatal(err)
				}
				if err := st.RecordReferral("FIRST", "buyer"); err != nil {
					t.Fatal(err)
				}
			}
			if err := st.CreateBillingSession(&store.BillingSession{ID: "local", ExternalID: "cs_paid", AccountID: "buyer", PaymentMethod: "stripe", AmountMicroUSD: 5_000_000, Status: "pending", CreatedAt: time.Now()}); err != nil {
				t.Fatal(err)
			}
			payload := []byte(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_paid","amount_total":500,"currency":"usd","payment_status":"paid","metadata":{"billing_session_id":"local","consumer_key":"buyer","referral_code":"REFER","app":"darkbloom"}}}}`)
			for range 2 {
				w := httptest.NewRecorder()
				s.Handler().ServeHTTP(w, signedStripeRequest(t, payload, "whsec_test", "/v1/billing/stripe/webhook"))
				if w.Code != 200 {
					t.Fatalf("%d %s", w.Code, w.Body.String())
				}
			}
			if st.GetBalance("buyer") != 5_000_000 {
				t.Fatal("duplicate deposit")
			}
			code, err := st.GetReferrerForAccount("buyer")
			if err != nil {
				t.Fatal(err)
			}
			if kind == "already_assigned" && code != "FIRST" || kind != "already_assigned" && code != "" {
				t.Fatalf("changed immutable attribution: %s", code)
			}
		})
	}
}

func TestCheckoutMigrationAcceptsBothSecretsAndCreditsOnce(t *testing.T) {
	s, st := stripePayoutsTestServer(t, true, nil)
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{StripeSecretKey: "rk_new", StripeWebhookSecret: "whsec_new", StripeLegacyWebhookSecret: "whsec_old", StripeConnectSecretKey: "rk_old"}))
	if err := st.CreateBillingSession(&store.BillingSession{ID: "local-session", ExternalID: "cs_stripe", AccountID: "buyer", PaymentMethod: "stripe", AmountMicroUSD: 5_000_000, Status: "pending", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateReferrer("promoter", "REFER"); err != nil {
		t.Fatal(err)
	}
	payload := []byte(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_stripe","amount_total":500,"currency":"usd","payment_status":"paid","metadata":{"billing_session_id":"local-session","consumer_key":"buyer","app":"darkbloom","referral_code":"REFER"}}}}`)
	for _, secret := range []string{"whsec_old", "whsec_new", "whsec_old"} {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, signedStripeRequest(t, payload, secret, "/v1/billing/stripe/webhook"))
		if w.Code != 200 {
			t.Fatalf("%s: %d %s", secret, w.Code, w.Body.String())
		}
	}
	if b, wd := st.GetBalanceWithWithdrawable("buyer"); b != 5_000_000 || wd != 0 {
		t.Fatalf("deposit %d/%d", b, wd)
	}
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, signedStripeRequest(t, payload, "whsec_wrong", "/v1/billing/stripe/webhook"))
	if w.Code != 400 {
		t.Fatal("wrong signature accepted")
	}
}

func TestConnectedAccountWebhookUsesSeparateSecretAndRequiresAccount(t *testing.T) {
	s, st := stripePayoutsTestServer(t, true, nil)
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{StripeConnectSecretKey: "rk_old", StripeConnectWebhookSecret: "whsec_platform", StripeConnectAccountsWebhookSecret: "whsec_accounts"}))
	for _, tc := range []struct {
		account, secret string
		want            int
	}{
		{"acct_provider", "whsec_accounts", 200}, {"", "whsec_accounts", 400}, {"acct_provider", "whsec_platform", 400},
	} {
		payload := []byte(fmt.Sprintf(`{"type":"unused.event","account":%q,"data":{"object":{}}}`, tc.account))
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, signedStripeRequest(t, payload, tc.secret, "/v1/billing/stripe/connect/accounts/webhook"))
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
	w := globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"5.00"}`)
	if w.Code != 502 {
		t.Fatal(w.Body.String())
	}
	rows, _ := st.ListStripeWithdrawals(u.AccountID, 10)
	if len(rows) != 1 || rows[0].Status != "pending" || rows[0].Refunded || st.GetBalance(u.AccountID) != 5_000_000 {
		t.Fatalf("unsafe refund: %+v", rows)
	}
}
