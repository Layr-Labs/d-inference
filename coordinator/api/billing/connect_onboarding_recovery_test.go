package billing

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// TestStripeOnboardRecreatesAccountOnServiceAgreementMismatch pins the
// migration path for AU/NZ/JP users whose accounts were created under the
// `full` agreement before we set `recipient`: re-running onboarding must
// create a NEW account under the recipient agreement (transfers-only).
func TestStripeOnboardRecreatesAccountOnServiceAgreementMismatch(t *testing.T) {
	var mu sync.Mutex
	var createBody url.Values

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet:
			// Existing AU account wrongly under the full agreement.
			_, _ = w.Write([]byte(healthyAccountJSON("acct_au_full", "AU", "full", false)))
		case r.URL.Path == "/v1/accounts" && r.Method == http.MethodPost:
			body, _ := io.ReadAll(r.Body)
			parsed, _ := url.ParseQuery(string(body))
			mu.Lock()
			createBody = parsed
			mu.Unlock()
			_, _ = w.Write([]byte(`{"id":"acct_au_recipient","country":"AU","tos_acceptance":{"service_agreement":"recipient"}}`))
		case strings.HasPrefix(r.URL.Path, "/v1/account_links"):
			_, _ = w.Write([]byte(`{"url":"https://connect.stripe.com/setup/e/au_new"}`))
		default:
			t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := seedUser(t, st, "acct-au-mig", "au@example.com")
	_ = st.SetUserStripeAccount(user.AccountID, "acct_au_full", "ready", "AU", "bank", "6789", false)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "acct_au_recipient" {
		t.Errorf("StripeAccountID = %q, want acct_au_recipient", refreshed.StripeAccountID)
	}
	if refreshed.StripeAccountCountry != "AU" {
		t.Errorf("country = %q, want AU", refreshed.StripeAccountCountry)
	}

	mu.Lock()
	defer mu.Unlock()
	if createBody == nil {
		t.Fatal("no account creation request was made")
	}
	if got := createBody.Get("tos_acceptance[service_agreement]"); got != "recipient" {
		t.Errorf("service_agreement = %q, want recipient", got)
	}
	if got := createBody.Get("capabilities[card_payments][requested]"); got != "" {
		t.Errorf("card_payments must not be requested for recipient accounts, got %q", got)
	}
	if got := createBody.Get("capabilities[transfers][requested]"); got != "true" {
		t.Errorf("transfers capability = %q, want true", got)
	}
	if got := createBody.Get("settings[payouts][schedule][interval]"); got != "daily" {
		t.Errorf("payout schedule = %q, want daily", got)
	}
	if got := createBody.Get("country"); got != "AU" {
		t.Errorf("country = %q, want AU", got)
	}
}

// TestStripeOnboardRecreatesAccountWhenGone pins recovery for users who
// closed their Stripe account: onboarding must create a fresh account
// instead of failing on the stale acct_… forever.
func TestStripeOnboardRecreatesAccountWhenGone(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet:
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":{"code":"account_invalid","message":"The provided key does not have access to account 'acct_gone'"}}`))
		case r.URL.Path == "/v1/accounts" && r.Method == http.MethodPost:
			_, _ = w.Write([]byte(`{"id":"acct_fresh","country":"NZ","tos_acceptance":{"service_agreement":"recipient"}}`))
		case strings.HasPrefix(r.URL.Path, "/v1/account_links"):
			_, _ = w.Write([]byte(`{"url":"https://connect.stripe.com/setup/e/fresh"}`))
		default:
			t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := seedUser(t, st, "acct-gone-1", "nz@example.com")
	_ = st.SetUserStripeAccount(user.AccountID, "acct_gone", "ready", "NZ", "bank", "6789", false)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "acct_fresh" {
		t.Errorf("StripeAccountID = %q, want acct_fresh", refreshed.StripeAccountID)
	}
}

// TestStripeOnboardHealsManualPayoutSchedule pins the self-heal: reusing a
// healthy account that still has the legacy manual payout schedule must flip
// it to daily so parked funds drain to the user's bank.
func TestStripeOnboardHealsManualPayoutSchedule(t *testing.T) {
	var mu sync.Mutex
	var scheduleUpdate url.Values

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet:
			acct := strings.Replace(healthyAccountJSON("acct_manual_1", "US", "full", false),
				`"interval":"daily"`, `"interval":"manual"`, 1)
			_, _ = w.Write([]byte(acct))
		case strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodPost:
			body, _ := io.ReadAll(r.Body)
			parsed, _ := url.ParseQuery(string(body))
			mu.Lock()
			scheduleUpdate = parsed
			mu.Unlock()
			_, _ = w.Write([]byte(healthyAccountJSON("acct_manual_1", "US", "full", false)))
		case strings.HasPrefix(r.URL.Path, "/v1/account_links"):
			_, _ = w.Write([]byte(`{"url":"https://connect.stripe.com/setup/e/manual"}`))
		default:
			t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := seedUser(t, st, "acct-manual-heal", "heal@example.com")
	_ = st.SetUserStripeAccount(user.AccountID, "acct_manual_1", "ready", "US", "bank", "6789", false)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{"country":"US"}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "acct_manual_1" {
		t.Errorf("account should be reused, got %q", refreshed.StripeAccountID)
	}

	mu.Lock()
	defer mu.Unlock()
	if scheduleUpdate == nil {
		t.Fatal("expected a POST /v1/accounts/{id} schedule heal")
	}
	if got := scheduleUpdate.Get("settings[payouts][schedule][interval]"); got != "daily" {
		t.Errorf("healed interval = %q, want daily", got)
	}
}
