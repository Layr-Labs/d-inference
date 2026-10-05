package billing_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func globalOnlyFixture(t *testing.T) (*billingFixture, *memory.MemoryStore, *store.User, *fakeGlobalStripe) {
	t.Helper()
	s, st, u, f := globalPayoutAPIFixture(t, false)
	base := s.Billing().GlobalPayouts().BaseURL
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{
		StripeGlobalPayoutsOnly: true, StripeGlobalPayoutsEnabled: true,
		StripeGlobalPayoutsSecretKey: "rk_global", StripeGlobalPayoutsFinancialAccount: "fa_gp",
		StripeGlobalPayoutsWebhookSecret: "whsec_test", StripeConnectReturnURL: "https://app.test/billing",
	}))
	s.Billing().GlobalPayouts().BaseURL = base
	if s.Billing().StripeConnect() != nil {
		t.Fatal("global-only fixture unexpectedly has Connect")
	}
	u.StripeAccountID, u.StripeAccountCountry, u.StripeAccountStatus = "acct_old", "US", "ready"
	if err := st.SetUserStripeAccount(u.AccountID, u.StripeAccountID, "ready", "US", "bank", "1111", true); err != nil {
		t.Fatal(err)
	}
	return s, st, u, f
}

func TestGlobalOnlyMigratesEveryConnectCountryWithoutErasingLegacyAccount(t *testing.T) {
	for _, country := range globalpayouts.Countries {
		if country.Rail != "connect" {
			continue
		}
		t.Run(country.Code, func(t *testing.T) {
			s, st, u, f := globalOnlyFixture(t)
			f.country, f.currency = strings.ToLower(country.Code), country.Currency
			u.StripeAccountCountry = country.Code
			w := globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"`+country.Code+`"}`)
			if w.Code != 200 || !strings.Contains(w.Body.String(), `"payout_rail":"global"`) {
				t.Fatalf("onboard: %d %s", w.Code, w.Body.String())
			}
			old, _ := st.GetUserByAccountID(u.AccountID)
			if old.StripeAccountID != "acct_old" {
				t.Fatal("lost legacy account identity")
			}
			if w := globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"5.00","method":"instant"}`); w.Code != 400 {
				t.Fatalf("accepted old client instant request: %s", w.Body.String())
			}
			if st.GetBalance(u.AccountID) != 20_000_000 {
				t.Fatal("onboarding or rejected request debited balance")
			}
		})
	}
}

func TestGlobalOnlyStatusAndOldClientsRequireSelfServiceBankSetup(t *testing.T) {
	s, st, u, _ := globalOnlyFixture(t)
	w := globalAPIRequest(t, s, u, "/v1/billing/stripe/status", "")
	var status map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status["payout_rail"] != "global" || status["migration_required"] != true || status["has_account"] != false || status["instant_eligible"] != false {
		t.Fatalf("status: %s", w.Body.String())
	}
	if _, err := st.GetGlobalRecipient(u.AccountID); err != store.ErrNotFound {
		t.Fatal("status silently created a recipient")
	}
	w = globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"5.00"}`)
	if w.Code != 409 || !strings.Contains(w.Body.String(), "bank_setup_required") {
		t.Fatalf("old client: %d %s", w.Code, w.Body.String())
	}
	if st.GetBalance(u.AccountID) != 20_000_000 {
		t.Fatal("old client caused a debit")
	}
}

func TestGlobalRecipientResetAndPausedCutoverNeverFallBackToConnect(t *testing.T) {
	s, st, u, f := globalOnlyFixture(t)
	f.country, f.currency = "us", "usd"
	if w := globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"US"}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	old, _ := st.GetGlobalRecipient(u.AccountID)
	if err := st.RemoveGlobalRecipient(u.AccountID); err != nil {
		t.Fatal(err)
	}
	reset, _ := st.GetGlobalRecipient(u.AccountID)
	if reset.ID == old.ID || reset.RecipientID != "" {
		t.Fatalf("reset did not fence old generation: %+v", reset)
	}
	base := s.Billing().GlobalPayouts().BaseURL
	// Even a rollback to hybrid policy cannot erase a user's migration fence.
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{MockMode: true, StripeGlobalPayoutsEnabled: true, StripeGlobalPayoutsSecretKey: "rk_gp", StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeConnectReturnURL: "https://app.test/billing"}))
	s.Billing().GlobalPayouts().BaseURL = base
	w := globalAPIRequest(t, s, u, "/v1/billing/stripe/status", "")
	if !strings.Contains(w.Body.String(), `"payout_rail":"global"`) {
		t.Fatal(w.Body.String())
	}
	w = globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"US"}`)
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"payout_rail":"global"`) {
		t.Fatal(w.Body.String())
	}
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{StripeGlobalPayoutsOnly: true, StripeGlobalPayoutsSecretKey: "rk_gp", StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeConnectReturnURL: "https://app.test/billing"}))
	w = globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"US"}`)
	if w.Code != 503 {
		t.Fatalf("paused onboarding %d", w.Code)
	}
	w = globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"5.00"}`)
	if w.Code < 400 || st.GetBalance(u.AccountID) != 20_000_000 {
		t.Fatal("paused cutover fell back")
	}
}

func TestGlobalFundingShortfallIncludesFeesAndDoesNotDebit(t *testing.T) {
	s, st, u, f := globalOnlyFixture(t)
	f.country, f.currency = "us", "usd"
	if w := globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"US"}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w := globalAPIRequest(t, s, u, "/v1/billing/stripe/quote", `{"amount_usd":"10.00"}`)
	var quote struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &quote); err != nil || quote.ID == "" {
		t.Fatal(w.Body.String())
	}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "financial_accounts") {
			_, _ = w.Write([]byte(`{"id":"fa_gp","status":"open","balance":{"available":{"usd":{"currency":"usd","value":1000}}}}`))
			return
		}
		f.serve(w, r)
	}))
	defer remote.Close()
	s.Billing().GlobalPayouts().BaseURL = remote.URL
	w = globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"10.00","quote_id":"`+quote.ID+`"}`)
	if w.Code != 503 || !strings.Contains(w.Body.String(), "payout_funding_unavailable") {
		t.Fatalf("%d %s", w.Code, w.Body.String())
	}
	if st.GetBalance(u.AccountID) != 20_000_000 || f.creates != 0 {
		t.Fatal("unfunded payout moved money")
	}
}

func TestGlobalOnlyUSOnboardingRequestsLocalBankCapability(t *testing.T) {
	s, _, u, _ := globalOnlyFixture(t)
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v2/core/accounts" {
			var body struct {
				Configuration struct {
					Recipient struct {
						Capabilities struct {
							BankAccounts map[string]any `json:"bank_accounts"`
						} `json:"capabilities"`
					} `json:"recipient"`
				} `json:"configuration"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
			}
			if _, ok := body.Configuration.Recipient.Capabilities.BankAccounts["local"]; !ok {
				t.Error("US onboarding did not request ACH/local")
			}
			if _, ok := body.Configuration.Recipient.Capabilities.BankAccounts["wire"]; ok {
				t.Error("US onboarding requested wire")
			}
			_, _ = w.Write([]byte(`{"id":"acct_us","identity":{"country":"us"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"url":"https://accounts.stripe.com/setup"}`))
	}))
	defer remote.Close()
	s.Billing().GlobalPayouts().BaseURL = remote.URL
	if w := globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"US"}`); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
}
