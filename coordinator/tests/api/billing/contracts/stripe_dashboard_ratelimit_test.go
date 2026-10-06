package billing_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

// Every call to this route is a live Stripe POST that mints a dashboard
// credential, so a valid session must not be able to loop it and burn the
// platform's Stripe request capacity. Drive the real mux: the limiter has to
// sit inside requirePrivyAuth (it keys on the account ID that middleware puts
// in the context), and dropping it from the chain must fail CI.
func TestStripeDashboardLinkRouteIsRateLimited(t *testing.T) {
	srv, st := stripeSessionServer(t)
	srv.SetFinancialRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))

	token := testkit.NewSessions(t, srv, st).Token("acct-dash-rl")

	call := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		return w
	}

	// First call passes the limiter and reaches the handler. This user has no
	// connected account, so the handler's own gate answers 409 — what matters
	// is that the limiter let it through.
	if w := call(); w.Code != http.StatusConflict {
		t.Fatalf("first call = %d, want 409 (limiter must not reject the first request): %s", w.Code, w.Body.String())
	}

	w := call()
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("second call = %d, want 429 — the dashboard route is missing rateLimitFinancial: %s", w.Code, w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("429 without Retry-After")
	}
}
