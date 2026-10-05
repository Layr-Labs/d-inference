package billing_test

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/billing"
)

// Tests for the Stripe Connect region policy (service agreements), the
// account-creation form differences between full and recipient agreements,
// the payout-schedule self-heal call, and the Stripe error classifiers.

func TestRequiredServiceAgreement(t *testing.T) {
	cases := []struct {
		platform, account, want string
	}{
		// Same country → full, always.
		{"US", "US", production.ServiceAgreementFull},
		{"US", "", production.ServiceAgreementFull}, // unknown country defaults to platform
		// Transfer region (US/CA/UK/EEA/CH) → full.
		{"US", "CA", production.ServiceAgreementFull},
		{"US", "GB", production.ServiceAgreementFull},
		{"US", "FR", production.ServiceAgreementFull},
		{"US", "DE", production.ServiceAgreementFull},
		{"US", "NO", production.ServiceAgreementFull},
		{"US", "CH", production.ServiceAgreementFull},
		{"US", "IS", production.ServiceAgreementFull},
		// Outside the transfer region → recipient. These are the exact
		// countries from the support reports ("Funds can't be sent to
		// accounts located in XX when the account is under the `full`
		// service agreement").
		{"US", "AU", production.ServiceAgreementRecipient},
		{"US", "NZ", production.ServiceAgreementRecipient},
		{"US", "JP", production.ServiceAgreementRecipient},
		{"US", "SG", production.ServiceAgreementRecipient},
		{"US", "MX", production.ServiceAgreementRecipient},
		{"US", "BR", production.ServiceAgreementRecipient},
		{"US", "IN", production.ServiceAgreementRecipient},
		// Case-insensitive: the platform country comes from configuration
		// (EIGENINFERENCE_STRIPE_CONNECT_COUNTRY) and may be lowercase; a
		// missed match would create US/EEA accounts as recipient.
		{"us", "US", production.ServiceAgreementFull},
		{"us", "DE", production.ServiceAgreementFull},
		{"gb", "fr", production.ServiceAgreementFull},
		{" us ", "AU", production.ServiceAgreementRecipient},
		{"us", "jp", production.ServiceAgreementRecipient},
	}
	for _, c := range cases {
		if got := production.RequiredServiceAgreement(c.platform, c.account); got != c.want {
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
	if _, err := client.CreateExpressAccount(production.CreateExpressAccountParams{
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
		wantInterval := "daily"
		if country == "JP" {
			// Stripe doesn't offer daily automatic payouts in Japan.
			wantInterval = "weekly"
		}
		if got := form.Get("settings[payouts][schedule][interval]"); got != wantInterval {
			t.Errorf("%s: payout schedule = %q, want %q", country, got, wantInterval)
		}
		if country == "JP" {
			if got := form.Get("settings[payouts][schedule][weekly_anchor]"); got != "monday" {
				t.Errorf("JP: weekly_anchor = %q, want monday", got)
			}
		}
	}
}

func TestUpdateAccountPayoutScheduleAuto(t *testing.T) {
	var captured *http.Request
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		captured = r
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		_, _ = w.Write([]byte(`{"id":"acct_heal"}`))
	})

	if err := client.UpdateAccountPayoutScheduleAuto("acct_heal", "US"); err != nil {
		t.Fatalf("update schedule: %v", err)
	}
	if captured.Method != http.MethodPost || captured.URL.Path != "/v1/accounts/acct_heal" {
		t.Errorf("call = %s %s, want POST /v1/accounts/acct_heal", captured.Method, captured.URL.Path)
	}
	if got := capturedBody.Get("settings[payouts][schedule][interval]"); got != "daily" {
		t.Errorf("interval = %q, want daily", got)
	}
}

func TestUpdateAccountPayoutScheduleAutoJapanUsesWeekly(t *testing.T) {
	var capturedBody url.Values
	_, client := withTestStripe(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		capturedBody, _ = url.ParseQuery(string(body))
		_, _ = w.Write([]byte(`{"id":"acct_jp"}`))
	})
	if err := client.UpdateAccountPayoutScheduleAuto("acct_jp", "JP"); err != nil {
		t.Fatalf("update schedule: %v", err)
	}
	if got := capturedBody.Get("settings[payouts][schedule][interval]"); got != "weekly" {
		t.Errorf("JP interval = %q, want weekly (Stripe has no daily payouts in Japan)", got)
	}
	if got := capturedBody.Get("settings[payouts][schedule][weekly_anchor]"); got != "monday" {
		t.Errorf("JP weekly_anchor = %q, want monday", got)
	}
}

func TestUpdateAccountPayoutScheduleAutoRequiresAccount(t *testing.T) {
	client := production.NewStripeConnect("sk_test_fake", "", "US", false, silentLogger())
	if err := client.UpdateAccountPayoutScheduleAuto("", "US"); err == nil {
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
		if got := production.IsAccountGoneErr(c.err); got != c.want {
			t.Errorf("IsAccountGoneErr(%v) = %v, want %v", c.err, got, c.want)
		}
	}
}

func TestIsServiceAgreementErr(t *testing.T) {
	// The exact error our AU/NZ/JP users hit in production.
	err := errors.New("stripe connect: create transfer: stripe 400: Funds can't be sent to accounts located in AU when the account is under the `full` service agreement. To learn more, see https://stripe.com/docs/connect/service-agreement-types.")
	if !production.IsServiceAgreementErr(err) {
		t.Error("should classify the full-service-agreement transfer error")
	}
	if production.IsServiceAgreementErr(errors.New("stripe 400: something else")) {
		t.Error("should not classify unrelated errors")
	}
	if production.IsServiceAgreementErr(nil) {
		t.Error("nil is not a service agreement error")
	}
}

func TestNormalizeServiceAgreement(t *testing.T) {
	// Live-API fact: full-agreement accounts omit the field entirely.
	if got := production.NormalizeServiceAgreement(""); got != production.ServiceAgreementFull {
		t.Errorf("absent field must normalize to full, got %q", got)
	}
	if got := production.NormalizeServiceAgreement("recipient"); got != production.ServiceAgreementRecipient {
		t.Errorf("recipient must pass through, got %q", got)
	}
	if got := production.NormalizeServiceAgreement("full"); got != production.ServiceAgreementFull {
		t.Errorf("full must pass through, got %q", got)
	}
}

// TestIsDefinitiveAPIErr pins the definitive-vs-indeterminate classification
// that gates withdrawal refunds: only non-conflict 4xx responses prove no
// money moved. 5xx (possibly side-effecting per Stripe's low-level error
// docs), 409 idempotency conflicts (original request may still be
// executing), and transport errors are indeterminate.
func TestIsDefinitiveAPIErr(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"transport", errors.New("api request: context deadline exceeded"), false},
		{"wrapped transport", fmt.Errorf("stripe connect: create transfer: %w", errors.New("read response: EOF")), false},
		{"definitive 400", &production.APIError{StatusCode: 400, Message: "boom"}, true},
		{"definitive 402", &production.APIError{StatusCode: 402, Code: "balance_insufficient", Message: "x"}, true},
		{"wrapped definitive", fmt.Errorf("stripe connect: create transfer: %w", &production.APIError{StatusCode: 400, Message: "boom"}), true},
		{"409 conflict", &production.APIError{StatusCode: 409, Code: "idempotency_key_in_use", Message: "in use"}, false},
		{"idempotency code on other status", &production.APIError{StatusCode: 400, Code: "idempotency_key_in_use", Message: "in use"}, false},
		{"500 indeterminate", &production.APIError{StatusCode: 500, Message: "unknown error"}, false},
		{"503 indeterminate", &production.APIError{StatusCode: 503, Message: "overloaded"}, false},
	}
	for _, c := range cases {
		if got := production.IsDefinitiveAPIErr(c.err); got != c.want {
			t.Errorf("%s: IsDefinitiveAPIErr = %v, want %v", c.name, got, c.want)
		}
	}
}
