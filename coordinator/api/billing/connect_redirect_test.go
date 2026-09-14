package billing

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestStripeOnboardRejectsForeignReturnURL(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-onboard-redir", "alice@example.com")

	// Default return URL is https://app.test/...; passing attacker.example
	// must be rejected before any Stripe call is made.
	body := `{"return_url":"https://attacker.example/billing"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400 on foreign host: %s", w.Code, w.Body.String())
	}
}

func TestStripeOnboardAllowsLocalhostForDev(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-onboard-local", "alice@example.com")

	body := `{"return_url":"http://localhost:3000/billing","country":"US"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d, want 200 for localhost: %s", w.Code, w.Body.String())
	}
}

func TestStripeOnboardRejectsJavascriptScheme(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-onboard-js", "alice@example.com")

	body := `{"return_url":"javascript:alert(1)"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 on non-http scheme", w.Code)
	}
}
