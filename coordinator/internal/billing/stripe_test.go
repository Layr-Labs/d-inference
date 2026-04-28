package billing

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
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
