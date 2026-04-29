package billing

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

func TestCreateCheckoutSessionAddsDashboardMetadata(t *testing.T) {
	var capturedPath string
	var capturedForm url.Values
	var capturedAuth string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedPath = r.URL.Path
		capturedAuth = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		capturedForm, _ = url.ParseQuery(string(body))

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"id":"cs_test_123","url":"https://checkout.stripe.com/c/pay/cs_test_123"}`))
	}))
	defer srv.Close()

	prev := stripeAPIBase
	stripeAPIBase = srv.URL
	t.Cleanup(func() { stripeAPIBase = prev })

	proc := NewStripeProcessor("sk_test_dashboard", "whsec_test", "https://app.darkbloom.dev/billing", "https://app.darkbloom.dev/billing", silentLogger())
	resp, err := proc.CreateCheckoutSession(CheckoutSessionRequest{
		AmountCents:   2500,
		Currency:      "usd",
		CustomerEmail: "buyer@example.com",
		Metadata: map[string]string{
			"billing_session_id": "billing-session-123",
			"consumer_key":       "consumer-abc",
			"coordinator_host":   "api.darkbloom.dev",
		},
	})
	if err != nil {
		t.Fatalf("create checkout session: %v", err)
	}
	if resp.SessionID != "cs_test_123" {
		t.Fatalf("session id = %q, want cs_test_123", resp.SessionID)
	}
	if capturedPath != "/v1/checkout/sessions" {
		t.Fatalf("path = %q, want /v1/checkout/sessions", capturedPath)
	}
	if capturedAuth != "Bearer sk_test_dashboard" {
		t.Fatalf("Authorization = %q", capturedAuth)
	}

	expectedMetadata := map[string]string{
		"app":                "darkbloom",
		"platform":           "eigeninference",
		"purchase_type":      "inference_credits",
		"source":             "coordinator",
		"billing_session_id": "billing-session-123",
		"consumer_key":       "consumer-abc",
		"coordinator_host":   "api.darkbloom.dev",
	}
	for key, want := range expectedMetadata {
		if got := capturedForm.Get("metadata[" + key + "]"); got != want {
			t.Errorf("metadata[%s] = %q, want %q", key, got, want)
		}
		if got := capturedForm.Get("payment_intent_data[metadata][" + key + "]"); got != want {
			t.Errorf("payment_intent_data metadata[%s] = %q, want %q", key, got, want)
		}
	}
	if got := capturedForm.Get("line_items[0][price_data][product_data][name]"); got != "Darkbloom Inference Credits" {
		t.Errorf("product name = %q", got)
	}
}

func TestCreateEnterpriseInvoiceUsesSendInvoiceTerms(t *testing.T) {
	var forms []url.Values
	var paths []string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		body, _ := io.ReadAll(r.Body)
		form, _ := url.ParseQuery(string(body))
		forms = append(forms, form)
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/invoiceitems":
			_ = json.NewEncoder(w).Encode(map[string]any{"id": "ii_test"})
		case "/v1/invoices":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":         "in_test",
				"status":     "draft",
				"amount_due": 1234,
			})
		case "/v1/invoices/in_test/finalize":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":         "in_test",
				"status":     "open",
				"amount_due": 1234,
				"due_date":   time.Now().Add(15 * 24 * time.Hour).Unix(),
			})
		case "/v1/invoices/in_test/send":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":                 "in_test",
				"status":             "open",
				"hosted_invoice_url": "https://invoice.stripe.test/in_test",
				"invoice_pdf":        "https://invoice.stripe.test/in_test.pdf",
				"amount_due":         1234,
			})
		default:
			http.Error(w, "unexpected path", http.StatusNotFound)
		}
	}))
	defer srv.Close()

	prev := stripeAPIBase
	stripeAPIBase = srv.URL
	t.Cleanup(func() { stripeAPIBase = prev })

	proc := NewStripeProcessor("sk_test_invoice", "whsec_test", "", "", silentLogger())
	resp, err := proc.CreateEnterpriseInvoice(EnterpriseInvoiceRequest{
		CustomerID:     "cus_test",
		AccountID:      "acct-ent",
		AmountCents:    1234,
		Currency:       "usd",
		Description:    "Darkbloom Enterprise usage",
		PeriodStart:    time.Unix(100, 0),
		PeriodEnd:      time.Unix(200, 0),
		TermsDays:      15,
		IdempotencyKey: "enterprise-invoice-test",
	})
	if err != nil {
		t.Fatalf("CreateEnterpriseInvoice: %v", err)
	}
	if resp.InvoiceID != "in_test" || resp.HostedInvoiceURL == "" {
		t.Fatalf("unexpected invoice response: %+v", resp)
	}
	if len(paths) != 4 {
		t.Fatalf("Stripe calls = %v, want 4 calls", paths)
	}
	if got := forms[1].Get("collection_method"); got != "send_invoice" {
		t.Fatalf("collection_method = %q, want send_invoice", got)
	}
	if got := forms[1].Get("days_until_due"); got != "15" {
		t.Fatalf("days_until_due = %q, want 15", got)
	}
	if got := forms[1].Get("pending_invoice_items_behavior"); got != "include" {
		t.Fatalf("pending_invoice_items_behavior = %q, want include", got)
	}
	if got := forms[0].Get("period[start]"); got != "100" {
		t.Fatalf("period[start] = %q, want 100", got)
	}
}
