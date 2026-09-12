package globalpayouts

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func eligibleBank(id string) BankMethod {
	m := BankMethod{ID: id, Type: "bank_account"}
	m.BankAccount.Country = "IN"
	m.BankAccount.SupportedCurrencies = []string{"inr"}
	m.UsageStatus.Payments = "eligible"
	return m
}

func TestBankMethodFindsDefaultOnLaterPage(t *testing.T) {
	var server *httptest.Server
	calls := 0
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Stripe-Context") != "acct_recipient" {
			t.Error("recipient context lost")
		}
		if r.URL.Query().Get("page") == "next" {
			_ = json.NewEncoder(w).Encode(map[string]any{"data": []BankMethod{eligibleBank("pm_default")}})
			return
		}
		first := make([]BankMethod, 100)
		for i := range first {
			first[i] = BankMethod{ID: "archived", Type: "bank_account"}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": first, "next_page_url": server.URL + bankMethodsPath + "?page=next"})
	}))
	defer server.Close()
	c := New("rk_test", "fa_test")
	c.BaseURL = server.URL
	r := &Recipient{ID: "acct_recipient"}
	r.Defaults.PayoutMethods = map[string]string{"inr": "pm_default"}
	m, err := c.BankMethod(context.Background(), r, "IN", "inr", "local")
	if err != nil || m.ID != "pm_default" || calls != 2 {
		t.Fatalf("later default: %v %v calls=%d", m, err, calls)
	}
}

func TestBankMethodDoesNotMistakeIncompletePaginationForMissingBank(t *testing.T) {
	for _, next := range []string{"https://other.invalid/v2/money_management/payout_methods?page=2", bankMethodsPath + "?limit=100", bankMethodsPath + "?page=fails"} {
		t.Run(next, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Get("page") == "fails" {
					w.WriteHeader(503)
					_, _ = w.Write([]byte(`{"error":{"code":"unavailable"}}`))
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"data": []BankMethod{eligibleBank("pm_one")}, "next_page_url": next})
			}))
			defer server.Close()
			c := New("rk_test", "fa_test")
			c.BaseURL = server.URL
			if _, err := c.BankMethod(context.Background(), &Recipient{ID: "acct_r"}, "IN", "inr", "local"); err == nil || errors.Is(err, ErrNoEligibleBankMethod) {
				t.Fatalf("incomplete pagination became missing bank: %v", err)
			}
		})
	}
}

func TestRecipientPolicyMinorUnitsAndBounds(t *testing.T) {
	for _, tc := range []struct {
		code     string
		min, max int64
		exp      int
	}{{"TW", 80000, 0, 2}, {"PA", 5000, 0, 2}, {"AM", 1210000, 0, 2}, {"MG", 13230000, 0, 2}, {"TN", 1, 100000000, 3}, {"RO", 1, 5000000, 2}} {
		c, _ := Lookup(tc.code)
		l := c.Limits()
		if l.Minimum != tc.min || l.Maximum != tc.max || l.CurrencyExponent != tc.exp {
			t.Fatalf("wrong minor-unit bounds: %s %+v", tc.code, l)
		}
		if err := c.ValidateRecipientAmount(Amount{Value: tc.min, Currency: c.Currency}); err != nil {
			t.Fatal(err)
		}
		if tc.min > 0 && c.ValidateRecipientAmount(Amount{Value: tc.min - 1, Currency: c.Currency}) == nil {
			t.Fatal("minimum not enforced")
		}
	}
}

func TestEstimatedFeesPreserveFractionalMinorUnitQuote(t *testing.T) {
	var q Quote
	if err := json.Unmarshal([]byte(`{"estimated_fees":[{"type":"foreign_exchange_fee","amount":{"currency":"usd","value":1.5}}]}`), &q); err != nil {
		t.Fatal(err)
	}
	if q.EstimatedFees[0].Amount.Value.String() != "1.5" {
		t.Fatal("fee estimate rounded or discarded")
	}
}
