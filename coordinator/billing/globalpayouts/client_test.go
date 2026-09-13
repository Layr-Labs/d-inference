package globalpayouts

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestBankMethodSelectionAndContext(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Stripe-Context") != "acct_recipient" || r.Header.Get("Stripe-Version") != APIVersion {
			t.Error("missing recipient context/version")
		}
		_, _ = w.Write([]byte(`{"data":[{"id":"pm_one","type":"bank_account","bank_account":{"country":"IN","last4":"1111","supported_currencies":["inr"],"enabled_delivery_options":["local"]},"usage_status":{"payments":"eligible"}},{"id":"pm_two","type":"bank_account","bank_account":{"country":"IN","last4":"2222","supported_currencies":["inr"],"enabled_delivery_options":["local"]},"usage_status":{"payments":"eligible"}}]}`))
	}))
	defer server.Close()
	c := New("rk_test_fake", "fa_test")
	c.BaseURL = server.URL
	r := &Recipient{ID: "acct_recipient"}
	if _, err := c.BankMethod(context.Background(), r, "IN", "inr", "local"); err == nil {
		t.Fatal("silently selected from multiple bank accounts")
	}
	r.Defaults.PayoutMethods = map[string]string{"inr": "pm_two"}
	m, err := c.BankMethod(context.Background(), r, "IN", "inr", "local")
	if err != nil || m.ID != "pm_two" {
		t.Fatalf("default bank: %v %v", m, err)
	}
	if _, err = c.BankMethod(context.Background(), r, "PK", "inr", "local"); err == nil {
		t.Fatal("accepted wrong bank country")
	}
}
func TestPaymentFailureClassification(t *testing.T) {
	for _, status := range []int{409, 429, 500, 502, 503} {
		if (&Error{Status: status}).Definitive() {
			t.Fatalf("HTTP %d can have an ambiguous payment outcome", status)
		}
	}
	for _, status := range []int{400, 401, 403, 404, 422} {
		if !(&Error{Status: status}).Definitive() {
			t.Fatalf("HTTP %d explicit rejection", status)
		}
	}
}
func TestCountryPolicySeparatesProducts(t *testing.T) {
	for _, code := range []string{"IN", "PK", "TW", "TR", "IS"} {
		c, ok := Lookup(code)
		if !ok || c.Rail != "global" || c.Capability == "" || c.Currency == "" {
			t.Fatalf("missing bank route %s", code)
		}
	}
	for _, code := range []string{"CN", "KH", "GI"} {
		if _, ok := Lookup(code); ok {
			t.Fatalf("unverified route advertised: %s", code)
		}
	}
	if c, ok := Lookup("LI"); !ok || c.Rail != "connect" {
		t.Fatal("Liechtenstein should retain Connect")
	}
}

func TestLiveBankShapeAndRecipientIncludes(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("include[0]") != "identity" || r.URL.Query().Get("include[1]") != "configuration.recipient" {
			t.Error("v2 include fields must be encoded as an array")
		}
		_, _ = w.Write([]byte(`{"id":"acct_recipient","identity":{"country":"US"}}`))
	}))
	defer server.Close()
	c := New("rk_test_fake", "fa_test")
	c.BaseURL = server.URL
	if _, err := c.Recipient(context.Background(), "acct_recipient"); err != nil {
		t.Fatal(err)
	}
	var m BankMethod
	// The live API omits enabled_delivery_options for eligible bank methods.
	if err := json.Unmarshal([]byte(`{"id":"usba_test","type":"bank_account","restricted":false,"bank_account":{"country":"US","archived":false,"supported_currencies":["usd"]},"usage_status":{"payments":"eligible"}}`), &m); err != nil {
		t.Fatal(err)
	}
	if !m.Eligible("US", "usd", "local") {
		t.Fatal("optional absent field fenced a live eligible bank")
	}
	m.Restricted = true
	if m.Eligible("US", "usd", "local") {
		t.Fatal("restricted bank accepted")
	}
}

func TestOnboardedRecipientCanUpdateBank(t *testing.T) {
	attempts := 0
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		var body struct {
			Account string                     `json:"account"`
			UseCase map[string]json.RawMessage `json:"use_case"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		var useCase string
		_ = json.Unmarshal(body.UseCase["type"], &useCase)
		if body.Account != "acct_ready" {
			t.Error("recipient changed")
		}
		if attempts == 1 {
			if useCase != "account_onboarding" {
				t.Error("wrong initial link")
			}
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"code":"invalid_fields"}}`))
			return
		}
		if useCase != "account_update" || body.UseCase["account_update"] == nil {
			t.Error("missing account update configuration")
		}
		_, _ = w.Write([]byte(`{"url":"https://accounts.stripe.com/update-bank"}`))
	}))
	defer remote.Close()
	client := New("rk_test", "fa_test")
	client.BaseURL = remote.URL
	link, err := client.OnboardingLink(context.Background(), "acct_ready", "https://app.test/billing", "https://app.test/billing")
	if err != nil || link == "" || attempts != 2 {
		t.Fatalf("bank update link: %q, %v, attempts=%d", link, err, attempts)
	}
}
