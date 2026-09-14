package billing

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

func TestStripeOnboardRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{"country":"US"}`))
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

func TestStripeOnboardCreatesAccountAndPersistsID(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-onboard-1", "alice@example.com")

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{"country":"US"}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["url"] == nil || !strings.Contains(resp["url"].(string), "/setup/mock/") {
		t.Errorf("expected mock setup URL, got %v", resp["url"])
	}

	// Confirm the user was persisted with an account ID + pending status.
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID == "" {
		t.Error("StripeAccountID was not persisted")
	}
	if refreshed.StripeAccountStatus != "pending" {
		t.Errorf("status = %q, want pending", refreshed.StripeAccountStatus)
	}
}

func TestStripeOnboardPassesCountryToStripe(t *testing.T) {
	var mu sync.Mutex
	var accountCreateBody url.Values

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		parsed, _ := url.ParseQuery(string(body))

		switch {
		case r.URL.Path == "/v1/accounts" && r.Method == http.MethodPost:
			mu.Lock()
			accountCreateBody = parsed
			mu.Unlock()
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"id":"acct_gb_test","type":"express","charges_enabled":false,"payouts_enabled":false,"details_submitted":false}`))
		case strings.HasPrefix(r.URL.Path, "/v1/account_links"):
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"url":"https://connect.stripe.com/setup/e/gb_test"}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := seedUser(t, st, "acct-country-1", "alice@example.com")

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard",
		strings.NewReader(`{"country":"GB"}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	mu.Lock()
	got := accountCreateBody.Get("country")
	mu.Unlock()
	if got != "GB" {
		t.Errorf("country sent to Stripe = %q, want GB", got)
	}
}

func TestStripeOnboardRequiresCountryForNewAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-country-2", "bob@example.com")

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard",
		strings.NewReader(`{}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want empty", refreshed.StripeAccountID)
	}
}

func TestStripeOnboardReusesExistingAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-reuse-1", "bob@example.com")

	// Pre-seed an existing Stripe account ID locked to the US.
	_ = st.SetUserStripeAccount(user.AccountID, "acct_existing_123", "ready", "US", "bank", "1234", false)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{"country":"US"}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["stripe_account_id"] != "acct_existing_123" {
		t.Errorf("expected reuse of acct_existing_123, got %v", resp["stripe_account_id"])
	}
}

func TestStripeOnboardCreatesNewAccountWhenCountryChanges(t *testing.T) {
	var mu sync.Mutex
	var createdCountries []string

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/accounts" && r.Method == http.MethodPost:
			body, _ := io.ReadAll(r.Body)
			parsed, _ := url.ParseQuery(string(body))
			mu.Lock()
			createdCountries = append(createdCountries, parsed.Get("country"))
			mu.Unlock()
			w.WriteHeader(200)
			id := "acct_" + strings.ToLower(parsed.Get("country")) + "_new"
			_, _ = w.Write([]byte(`{"id":"` + id + `","type":"express","charges_enabled":false,"payouts_enabled":false,"details_submitted":false}`))
		case strings.HasPrefix(r.URL.Path, "/v1/account_links"):
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"url":"https://connect.stripe.com/setup/e/new"}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := seedUser(t, st, "acct-country-change-1", "alice@example.com")

	// Pre-seed an existing Stripe account ID locked to the US.
	_ = st.SetUserStripeAccount(user.AccountID, "acct_us_old", "pending", "US", "", "", false)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard",
		strings.NewReader(`{"country":"GB"}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["stripe_account_id"] != "acct_gb_new" {
		t.Errorf("expected new GB account, got %v", resp["stripe_account_id"])
	}

	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountCountry != "GB" {
		t.Errorf("StripeAccountCountry = %q, want GB", refreshed.StripeAccountCountry)
	}
	if refreshed.StripeAccountStatus != "pending" {
		t.Errorf("status = %q, want pending", refreshed.StripeAccountStatus)
	}

	mu.Lock()
	countries := append([]string(nil), createdCountries...)
	mu.Unlock()
	if len(countries) != 1 || countries[0] != "GB" {
		t.Errorf("Stripe create account countries = %v, want [GB]", countries)
	}
}

func TestStripeOnboardCreatesNewAccountWhenExistingCountryUnknown(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-country-unknown-1", "carol@example.com")

	// Simulates users created before stripe_account_country existed. If they
	// explicitly select a country, don't reuse the unknown-country account.
	_ = st.SetUserStripeAccount(user.AccountID, "acct_old_unknown", "pending", "", "", "", false)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard",
		strings.NewReader(`{"country":"GB"}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID == "acct_old_unknown" {
		t.Fatal("expected a new Stripe account for explicit country selection")
	}
	if refreshed.StripeAccountCountry != "GB" {
		t.Errorf("StripeAccountCountry = %q, want GB", refreshed.StripeAccountCountry)
	}
}
