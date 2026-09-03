package api

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

// --- Onboard ---

func TestStripeOnboardRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{"country":"US"}`))
	w := httptest.NewRecorder()
	srv.handleStripeOnboard(w, req)
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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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

// --- Status ---

func TestStripeStatusReportsCurrentState(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-status-1", "alice@example.com")
	_ = st.SetUserStripeAccount(user.AccountID, "acct_x", "ready", "", "card", "4242", true)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodGet, "/v1/billing/stripe/status", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeStatus(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["status"] != "ready" {
		t.Errorf("status = %v", resp["status"])
	}
	if resp["destination_type"] != "card" {
		t.Errorf("destination_type = %v", resp["destination_type"])
	}
	if resp["destination_last4"] != "4242" {
		t.Errorf("destination_last4 = %v", resp["destination_last4"])
	}
	if resp["instant_eligible"] != true {
		t.Errorf("instant_eligible = %v", resp["instant_eligible"])
	}
}

// --- Open-redirect protection ---

func TestStripeOnboardRejectsForeignReturnURL(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-onboard-redir", "alice@example.com")

	// Default return URL is https://app.test/...; passing attacker.example
	// must be rejected before any Stripe call is made.
	body := `{"return_url":"https://attacker.example/billing"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 on non-http scheme", w.Code)
	}
}

// --- Service-agreement / dead-account recovery (issues #1 and #3) ---

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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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
	srv.handleStripeOnboard(w, req)

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
