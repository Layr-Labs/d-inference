package billing

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
)

func TestStripeDashboardLinkRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	w := httptest.NewRecorder()
	srv.StripeDashboardLink(w, req)
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
	srv.StripeDashboardLink(w, req)

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
			srv.StripeDashboardLink(w, req)

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
	srv.StripeDashboardLink(w, req)

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
	srv.StripeDashboardLink(w, req)

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
	srv.StripeDashboardLink(w, req)

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

func TestStripeUnlinkClearsAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-unlink-1", "unlink@example.com", false)

	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeUnlink(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["unlinked"] != true {
		t.Errorf("unlinked = %v, want true", resp["unlinked"])
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want empty", refreshed.StripeAccountID)
	}
	if refreshed.StripeAccountStatus != "" {
		t.Errorf("status = %q, want empty", refreshed.StripeAccountStatus)
	}

	// Second unlink is a no-op.
	refreshed, _ = st.GetUserByAccountID(user.AccountID)
	req2 := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req2 = withPrivyUser(req2, refreshed)
	w2 := httptest.NewRecorder()
	srv.StripeUnlink(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("second unlink got %d", w2.Code)
	}
	var resp2 map[string]any
	_ = json.Unmarshal(w2.Body.Bytes(), &resp2)
	if resp2["unlinked"] != false {
		t.Errorf("second unlink = %v, want false", resp2["unlinked"])
	}
}

func TestStripeUnlinkRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	w := httptest.NewRecorder()
	srv.StripeUnlink(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}
