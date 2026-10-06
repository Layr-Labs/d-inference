package billing_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/billing"
)

// A Stripe validation error can repeat request values, such as the
// customer_email that checkout sends. The checkout handler logs the error.
func TestStripeCheckoutErrorsOmitResponseBody(t *testing.T) {
	const echoedEmail = "stripe.echo@example.com"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"Invalid email address: ` + echoedEmail + `","param":"customer_email"}}`))
	}))
	defer srv.Close()
	prev := production.SetStripeAPIBaseForTest(srv.URL)
	t.Cleanup(func() { production.SetStripeAPIBaseForTest(prev) })
	proc := production.NewStripeProcessor("sk_test_errors", "whsec_test", "https://app.example.test/billing", "https://app.example.test/billing", silentLogger())

	_, createErr := proc.CreateCheckoutSession(production.CheckoutSessionRequest{AmountCents: 2500, CustomerEmail: echoedEmail})
	_, retrieveErr := proc.RetrieveSession("cs_test_errors")
	for name, err := range map[string]error{"create": createErr, "retrieve": retrieveErr} {
		if err == nil || !strings.Contains(err.Error(), "status 400") {
			t.Fatalf("%s error = %v, want the Stripe status code", name, err)
		}
		if strings.Contains(err.Error(), echoedEmail) {
			t.Errorf("%s error contains the Stripe response body: %v", name, err)
		}
	}
}
