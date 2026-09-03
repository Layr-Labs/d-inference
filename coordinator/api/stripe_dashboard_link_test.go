package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// --- Express Dashboard link ---
//
// The self-serve path for changing the payout bank account on an already
// onboarded account. The onboarding link can't do this (it only collects
// outstanding requirements, and a ready account has none), so this endpoint is
// the only thing standing between a provider and a support ticket.

func TestStripeDashboardLinkRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

func TestStripeDashboardLinkRequiresLinkedAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-dash-none", "nobank@example.com")

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	if got := errorTypeOf(t, w.Body.Bytes()); got != "not_onboarded" {
		t.Errorf("error type = %q", got)
	}
}

// Stripe has no Express Dashboard to log into until the account submits its
// details, so a half-onboarded account must be told to finish setup rather
// than handed a raw Stripe error suggesting a retry that can never work.
// Restricted and rejected accounts DO have a dashboard and must get through.
func TestStripeDashboardLinkStatusGate(t *testing.T) {
	cases := []struct {
		status   string
		wantCode int
	}{
		{"", http.StatusConflict},
		{stripeStatusPending, http.StatusConflict},
		{stripeStatusReady, http.StatusOK},
		{stripeStatusRestricted, http.StatusOK},
		{stripeStatusRejected, http.StatusOK},
	}
	for _, tc := range cases {
		name := tc.status
		if name == "" {
			name = "empty"
		}
		t.Run(name, func(t *testing.T) {
			srv, st := stripePayoutsTestServer(t, true, nil)
			user := seedUser(t, st, "acct-dash-"+name, name+"@example.com")
			if err := st.SetUserStripeAccount(user.AccountID, "acct_dash_"+name, tc.status, "US", "bank", "6789", false); err != nil {
				t.Fatal(err)
			}
			user, _ = st.GetUserByAccountID(user.AccountID)

			req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
			req = withPrivyUser(req, user)
			w := httptest.NewRecorder()
			srv.handleStripeDashboardLink(w, req)

			if w.Code != tc.wantCode {
				t.Fatalf("status %q: got %d, want %d: %s", tc.status, w.Code, tc.wantCode, w.Body.String())
			}
			if tc.wantCode == http.StatusConflict {
				if got := errorTypeOf(t, w.Body.Bytes()); got != "not_onboarded" {
					t.Errorf("error type = %q, want not_onboarded", got)
				}
			}
		})
	}
}

// The route-level middleware is the only thing keeping API keys out: requireAuth
// also populates the user context for account-bound keys and provider device
// tokens, so requirePrivyUser inside the handler is not a second line of
// defense. Drive the real mux so a swap to requireAuth can't pass CI.
func TestStripeDashboardLinkRouteRejectsAPIKey(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-dash-key", "keyholder@example.com", false)

	rawKey, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
	if err != nil {
		t.Fatalf("create api key: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req.Header.Set("Authorization", "Bearer "+rawKey)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("got %d, want 403 (API keys must not mint payout dashboard sessions): %s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), "connect.stripe.com") {
		t.Error("response leaked a login link to an API-key caller")
	}
}

func TestStripeDashboardLinkReturnsLoginURL(t *testing.T) {
	var mu sync.Mutex
	var gotPath string
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gotPath = r.URL.Path
		mu.Unlock()
		_, _ = w.Write([]byte(`{"object":"login_link","url":"https://connect.stripe.com/express/acct_x/tok"}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-dash-ok", "dash@example.com", false)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["url"] != "https://connect.stripe.com/express/acct_x/tok" {
		t.Errorf("url = %v", resp["url"])
	}
	if resp["stripe_account_id"] != user.StripeAccountID {
		t.Errorf("stripe_account_id = %v, want %q", resp["stripe_account_id"], user.StripeAccountID)
	}
	mu.Lock()
	defer mu.Unlock()
	if want := "/v1/accounts/" + user.StripeAccountID + "/login_links"; gotPath != want {
		t.Errorf("Stripe path = %q, want %q", gotPath, want)
	}
}

// An account the user closed on Stripe's side must be unlinked here too,
// otherwise the UI keeps offering a button that can only ever fail.
func TestStripeDashboardLinkUnlinksGoneAccount(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"code":"account_invalid","message":"No such account"}}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-dash-gone", "gone@example.com", false)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	if got := errorTypeOf(t, w.Body.Bytes()); got != "stripe_account_gone" {
		t.Errorf("error type = %q", got)
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want cleared", refreshed.StripeAccountID)
	}
}

// A transient Stripe failure must not unlink the account — the user's payout
// destination is still perfectly valid.
func TestStripeDashboardLinkKeepsAccountOnTransientError(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"type":"api_error","message":"Stripe is down"}}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-dash-5xx", "flaky@example.com", false)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != user.StripeAccountID {
		t.Errorf("StripeAccountID = %q, want %q (untouched)", refreshed.StripeAccountID, user.StripeAccountID)
	}
	if refreshed.StripeAccountStatus != "ready" {
		t.Errorf("status = %q, want ready (untouched)", refreshed.StripeAccountStatus)
	}
}

// errorTypeOf pulls error.type out of a coordinator error envelope.
func errorTypeOf(t *testing.T, body []byte) string {
	t.Helper()
	var resp map[string]any
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal error body %q: %v", body, err)
	}
	errObj, _ := resp["error"].(map[string]any)
	s, _ := errObj["type"].(string)
	return s
}
