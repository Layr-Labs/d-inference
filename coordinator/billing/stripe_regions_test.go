package billing

// Tests for the Stripe Connect region policy (service agreements), the
// account-creation form differences between full and recipient agreements,
// the payout-schedule self-heal call, and the Stripe error classifiers.

import (
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func TestRequiredServiceAgreement(t *testing.T) {
	cases := []struct {
		platform, account, want string
	}{
		// Same country → full, always.
		{"US", "US", ServiceAgreementFull},
		{"US", "", ServiceAgreementFull}, // unknown country defaults to platform
		// Transfer region (US/CA/UK/EEA/CH) → full.
		{"US", "CA", ServiceAgreementFull},
		{"US", "GB", ServiceAgreementFull},
		{"US", "FR", ServiceAgreementFull},
		{"US", "DE", ServiceAgreementFull},
		{"US", "NO", ServiceAgreementFull},
		{"US", "CH", ServiceAgreementFull},
		{"US", "IS", ServiceAgreementFull},
		// Outside the transfer region → recipient. These are the exact
		// countries from the support reports ("Funds can't be sent to
		// accounts located in XX when the account is under the `full`
		// service agreement").
		{"US", "AU", ServiceAgreementRecipient},
		{"US", "NZ", ServiceAgreementRecipient},
		{"US", "JP", ServiceAgreementRecipient},
		{"US", "SG", ServiceAgreementRecipient},
		{"US", "MX", ServiceAgreementRecipient},
		{"US", "BR", ServiceAgreementRecipient},
		{"US", "IN", ServiceAgreementRecipient},
	}
	for _, c := range cases {
		if got := RequiredServiceAgreement(c.platform, c.account); got != c.want {
			t.Errorf("RequiredServiceAgreement(%q, %q) = %q, want %q", c.platform, c.account, got, c.want)
		}
	}
}

// captureAccountCreate runs CreateExpressAccount against a fake Stripe and
// returns the posted form.
func captureAccountCreate(t *testing.T, country string) url.Values {
	t.Helper()
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"acct_x","country":"` + country + `"}`))
	})
	if _, err := client.CreateExpressAccount(CreateExpressAccountParams{
		Email:   "a@b.com",
		Country: country,
	}); err != nil {
		t.Fatalf("create account: %v", err)
	}
	return capturedBody
}

func TestCreateExpressAccountFullAgreementForm(t *testing.T) {
	form := captureAccountCreate(t, "US")
	if got := form.Get("tos_acceptance[service_agreement]"); got != "" {
		t.Errorf("US accounts must not set a service agreement (defaults to full), got %q", got)
	}
	if got := form.Get("capabilities[card_payments][requested]"); got != "true" {
		t.Errorf("full accounts request card_payments, got %q", got)
	}
	if got := form.Get("capabilities[transfers][requested]"); got != "true" {
		t.Errorf("transfers capability = %q, want true", got)
	}
	if got := form.Get("settings[payouts][schedule][interval]"); got != "daily" {
		t.Errorf("payout schedule = %q, want daily (manual strands funds)", got)
	}
}

func TestCreateExpressAccountRecipientAgreementForm(t *testing.T) {
	for _, country := range []string{"AU", "NZ", "JP"} {
		form := captureAccountCreate(t, country)
		if got := form.Get("tos_acceptance[service_agreement]"); got != "recipient" {
			t.Errorf("%s: service_agreement = %q, want recipient", country, got)
		}
		if got := form.Get("capabilities[card_payments][requested]"); got != "" {
			t.Errorf("%s: card_payments is incompatible with the recipient agreement, got %q", country, got)
		}
		if got := form.Get("capabilities[transfers][requested]"); got != "true" {
			t.Errorf("%s: transfers capability = %q, want true", country, got)
		}
		if got := form.Get("settings[payouts][schedule][interval]"); got != "daily" {
			t.Errorf("%s: payout schedule = %q, want daily", country, got)
		}
	}
}

func TestUpdateAccountPayoutScheduleDaily(t *testing.T) {
	var captured *http.Request
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		captured = r
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		_, _ = w.Write([]byte(`{"id":"acct_heal"}`))
	})

	if err := client.UpdateAccountPayoutScheduleDaily("acct_heal"); err != nil {
		t.Fatalf("update schedule: %v", err)
	}
	if captured.Method != http.MethodPost || captured.URL.Path != "/v1/accounts/acct_heal" {
		t.Errorf("call = %s %s, want POST /v1/accounts/acct_heal", captured.Method, captured.URL.Path)
	}
	if got := capturedBody.Get("settings[payouts][schedule][interval]"); got != "daily" {
		t.Errorf("interval = %q, want daily", got)
	}
}

func TestUpdateAccountPayoutScheduleDailyRequiresAccount(t *testing.T) {
	client := NewStripeConnect("sk_test_fake", "", "US", false, silentLogger())
	if err := client.UpdateAccountPayoutScheduleDaily(""); err == nil {
		t.Fatal("expected error for empty account id")
	}
}

func TestGetAccountParsesAgreementCountryAndSchedule(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{
			"id": "acct_au_1",
			"country": "AU",
			"default_currency": "aud",
			"payouts_enabled": true,
			"tos_acceptance": {"service_agreement": "recipient"},
			"settings": {"payouts": {"schedule": {"interval": "manual"}}}
		}`))
	})
	acct, err := client.GetAccount("acct_au_1")
	if err != nil {
		t.Fatalf("get account: %v", err)
	}
	if acct.Country != "AU" {
		t.Errorf("country = %q, want AU", acct.Country)
	}
	if acct.DefaultCurrency != "aud" {
		t.Errorf("default_currency = %q, want aud", acct.DefaultCurrency)
	}
	if acct.ServiceAgreement != "recipient" {
		t.Errorf("service_agreement = %q, want recipient", acct.ServiceAgreement)
	}
	if acct.PayoutInterval != "manual" {
		t.Errorf("payout_interval = %q, want manual", acct.PayoutInterval)
	}
}

func TestStripeErrorSurfacesCode(t *testing.T) {
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":"account_invalid","message":"The provided key does not have access to account 'acct_x'"}}`))
	})
	_, err := client.GetAccount("acct_x")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "account_invalid") {
		t.Errorf("error should include the Stripe error code, got %v", err)
	}
}

func TestIsAccountGoneErr(t *testing.T) {
	cases := []struct {
		err  error
		want bool
	}{
		{nil, false},
		{errors.New("stripe 400: No such destination: 'acct_1ThPlKHE4YfFZAXZ'"), true},
		{errors.New("stripe 404: No such account: 'acct_x'"), true},
		{errors.New("stripe 403 [account_invalid]: The provided key does not have access to account 'acct_x'"), true},
		{errors.New("stripe 400: The provided key 'sk_…' does not have access to account 'acct_x'"), true},
		{errors.New("stripe 400: insufficient platform funds"), false},
		{errors.New("stripe 500: internal"), false},
	}
	for _, c := range cases {
		if got := IsAccountGoneErr(c.err); got != c.want {
			t.Errorf("IsAccountGoneErr(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

func TestIsServiceAgreementErr(t *testing.T) {
	// The exact error our AU/NZ/JP users hit in production.
	err := errors.New("stripe connect: create transfer: stripe 400: Funds can't be sent to accounts located in AU when the account is under the `full` service agreement. To learn more, see https://stripe.com/docs/connect/service-agreement-types.")
	if !IsServiceAgreementErr(err) {
		t.Error("should classify the full-service-agreement transfer error")
	}
	if IsServiceAgreementErr(errors.New("stripe 400: something else")) {
		t.Error("should not classify unrelated errors")
	}
	if IsServiceAgreementErr(nil) {
		t.Error("nil is not a service agreement error")
	}
}
