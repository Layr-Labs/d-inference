package api

// Stripe Payouts handler tests. These exercise the onboard → status →
// withdraw → webhook lifecycle end-to-end with:
//   * the real handlers (no mocks of our own code)
//   * an in-memory store
//   * a Stripe-API HTTP mock (so transfer/payout calls return deterministic
//     IDs and we can assert on requests)
//   * mock-mode billing for the happy path tests, real-HTTP for failure-path
//     tests.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// stripePayoutsTestServer wires up a Server with an in-memory store and a
// billing service whose Stripe Connect client points at the supplied fake
// Stripe HTTP server. Pass mockMode=true to bypass Stripe entirely.
func stripePayoutsTestServer(t *testing.T, mockMode bool, fakeStripe *httptest.Server, opts ...billing.Config) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	cfg := billing.Config{
		MockMode:                     mockMode,
		StripeConnectReturnURL:       "https://app.test/billing?return=1",
		StripeConnectRefreshURL:      "https://app.test/billing?refresh=1",
		StripeConnectPlatformCountry: "US",
	}
	if !mockMode {
		cfg.StripeSecretKey = "sk_test_fake"
		cfg.StripeConnectWebhookSecret = "whsec_test"
	}
	if len(opts) > 0 {
		// Allow tests to override individual fields by merging.
		o := opts[0]
		if o.StripeSecretKey != "" {
			cfg.StripeSecretKey = o.StripeSecretKey
		}
		if o.StripeConnectWebhookSecret != "" {
			cfg.StripeConnectWebhookSecret = o.StripeConnectWebhookSecret
		}
	}

	if fakeStripe != nil {
		// Repoint the Stripe API base URL for the duration of the test.
		t.Cleanup(setStripeAPIBase(fakeStripe.URL))
	}

	ledger := payments.NewLedger(st)
	srv.SetBilling(billing.NewService(st, ledger, logger, cfg))
	return srv, st
}

// setStripeAPIBase swaps billing.stripeAPIBase to point at our fake server,
// returning a cleanup func to restore it.
func setStripeAPIBase(url string) func() {
	prev := billing.SetStripeAPIBaseForTest(url)
	return func() { billing.SetStripeAPIBaseForTest(prev) }
}

// healthyAccountJSON is what a fake Stripe returns for GET /v1/accounts/{id}:
// a fully onboarded account under the given service agreement, on the
// automatic daily payout schedule. instantEligible adds a debit-card
// destination.
func healthyAccountJSON(id, country, agreement string, instantEligible bool) string {
	ext := `{"object":"bank_account","last4":"6789","default_for_currency":true}`
	if instantEligible {
		ext = `{"object":"card","brand":"visa","funding":"debit","last4":"4242","default_for_currency":true}`
	}
	return `{"id":"` + id + `","country":"` + country + `","default_currency":"usd",
		"charges_enabled":true,"payouts_enabled":true,"details_submitted":true,
		"tos_acceptance":{"service_agreement":"` + agreement + `"},
		"settings":{"payouts":{"schedule":{"interval":"daily"}}},
		"external_accounts":{"data":[` + ext + `]}}`
}

// seedUser inserts a Privy-linked user into the store and returns it.
func seedUser(t *testing.T, st *store.MemoryStore, accountID, email string) *store.User {
	t.Helper()
	u := &store.User{
		AccountID:   accountID,
		PrivyUserID: "did:privy:" + accountID,
		Email:       email,
	}
	if err := st.CreateUser(u); err != nil {
		t.Fatalf("create user: %v", err)
	}
	got, _ := st.GetUserByAccountID(accountID)
	return got
}

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

// --- Withdraw ---

func TestStripeWithdrawRejectsWithoutOnboarding(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-w-1", "alice@example.com")
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("got %d, want 403", w.Code)
	}
}

func TestStripeWithdrawRejectsBelowMinimum(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-min", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"0.50","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400", w.Code)
	}
}

func TestStripeWithdrawRejectsInstantWithoutDebitCard(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-inst-1", "alice@example.com", false /* instant_eligible */)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "instant_unavailable" {
		t.Errorf("error type = %v", errObj["type"])
	}
}

func TestStripeWithdrawStandardSuccess(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-std", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["fee_usd"] != "0.00" {
		t.Errorf("standard fee should be 0, got %v", resp["fee_usd"])
	}
	if resp["net_usd"] != "5.00" {
		t.Errorf("net should equal gross for standard, got %v", resp["net_usd"])
	}
	if resp["amount_usd"] != "5.00" {
		t.Errorf("amount = %v", resp["amount_usd"])
	}
	if balance, _ := resp["balance_micro_usd"].(float64); int64(balance) != 5_000_000 {
		t.Errorf("balance = %v, want 5_000_000", resp["balance_micro_usd"])
	}

	// Confirm a withdrawal row was persisted.
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Method != "standard" {
		t.Errorf("method = %q", wds[0].Method)
	}
	if wds[0].FeeMicroUSD != 0 {
		t.Errorf("persisted fee = %d", wds[0].FeeMicroUSD)
	}
	if wds[0].NetMicroUSD != 5_000_000 {
		t.Errorf("persisted net = %d", wds[0].NetMicroUSD)
	}
}

func TestStripeWithdrawInstantAppliesFee(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-inst", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 100_000_000, store.LedgerDeposit, "seed")

	// $50 instant → 1.5% fee = $0.75 → net $49.25 → balance after = $50
	body := `{"amount_usd":"50.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["fee_usd"] != "0.75" {
		t.Errorf("fee_usd = %v, want 0.75", resp["fee_usd"])
	}
	if resp["net_usd"] != "49.25" {
		t.Errorf("net_usd = %v, want 49.25", resp["net_usd"])
	}
	if resp["amount_usd"] != "50.00" {
		t.Errorf("amount_usd = %v", resp["amount_usd"])
	}
	if resp["eta"] != "~30 minutes" {
		t.Errorf("eta = %v", resp["eta"])
	}
	if balance, _ := resp["balance_micro_usd"].(float64); int64(balance) != 50_000_000 {
		t.Errorf("balance = %v, want 50_000_000", resp["balance_micro_usd"])
	}
}

func TestStripeWithdrawSmallInstantHitsFloor(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-small", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	// $5 instant → 1.5% = $0.075 < $0.50 → fee snaps to $0.50 → net $4.50
	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["fee_usd"] != "0.50" {
		t.Errorf("fee_usd = %v, want 0.50 (floor)", resp["fee_usd"])
	}
	if resp["net_usd"] != "4.50" {
		t.Errorf("net_usd = %v", resp["net_usd"])
	}
}

func TestStripeWithdrawInsufficientBalance(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-poor", "alice@example.com", false)
	// No credit seeded.

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400", w.Code)
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "insufficient_withdrawable" {
		t.Errorf("error type = %v", errObj["type"])
	}
}

// TestStripeWithdrawTransferFailureRefunds exercises the ledger-refund branch
// when Stripe rejects transfers.create. We use a real-HTTP Stripe Connect
// client backed by a fake Stripe server that returns 400 on /v1/transfers.
func TestStripeWithdrawTransferFailureRefunds(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-w-fail", "US", "full", false)))
			return
		}
		if r.URL.Path == "/v1/transfers" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"insufficient platform funds","type":"invalid_request_error"}}`))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-fail", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance after refund = %d, want 10_000_000 (full original)", bal)
	}
	// Ledger should now have: deposit (+10), charge (-5), refund (+5).
	entries := st.LedgerHistory(user.AccountID)
	if len(entries) != 3 {
		t.Fatalf("expected 3 ledger entries, got %d", len(entries))
	}
	// Newest first: refund, charge, deposit.
	if entries[0].Type != store.LedgerRefund {
		t.Errorf("entries[0].Type = %q, want refund", entries[0].Type)
	}
}

func TestStripeWithdrawPersistsRowAsPendingFirst(t *testing.T) {
	// Verify the row exists before any Stripe call returns. We use a fake
	// Stripe that records when CreateTransfer is called and the test then
	// asserts that the DB had a "pending" row at that moment.
	var rowSeenAtTransferTime *store.StripeWithdrawal
	st := store.NewMemory(store.Config{AdminKey: "test-key"})

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-pers-1", "US", "full", false)))
			return
		}
		if r.URL.Path == "/v1/transfers" {
			// Snapshot the only withdrawal in the store at the moment of the
			// transfer call; should already be persisted with status=pending.
			wds, _ := st.ListStripeWithdrawals("acct-pers-1", 0)
			if len(wds) == 1 {
				cp := wds[0]
				rowSeenAtTransferTime = &cp
			}
			_, _ = w.Write([]byte(`{"id":"tr_pers","amount":500,"destination":"acct_x","created":1700000000}`))
			return
		}
		// Standard withdrawals must NOT create manual payouts — Stripe's
		// automatic daily schedule delivers the funds.
		t.Errorf("unexpected Stripe call: %s", r.URL.Path)
	}))
	defer fakeStripe.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(setStripeAPIBase(fakeStripe.URL))
	ledger := payments.NewLedger(st)
	srv.SetBilling(billing.NewService(st, ledger, logger, billing.Config{
		StripeSecretKey:              "sk_test_fake",
		StripeConnectWebhookSecret:   "whsec_test",
		StripeConnectReturnURL:       "https://app.test/billing",
		StripeConnectRefreshURL:      "https://app.test/billing",
		StripeConnectPlatformCountry: "US",
	}))

	user := readyUser(t, st, "acct-pers-1", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	if rowSeenAtTransferTime == nil {
		t.Fatal("withdrawal row should have been persisted before the transfer call")
	}
	if rowSeenAtTransferTime.Status != "pending" {
		t.Errorf("at transfer-time status was %q, want pending", rowSeenAtTransferTime.Status)
	}

	// Final state: transferred, no payout ID — delivery is Stripe's
	// automatic daily sweep, whose payout.paid webhook completes the row.
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Status != "transferred" {
		t.Errorf("final status = %q, want transferred", wds[0].Status)
	}
	if wds[0].TransferID != "tr_pers" {
		t.Errorf("transfer id not persisted: %+v", wds[0])
	}
	if wds[0].PayoutID != "" {
		t.Errorf("standard withdrawal should have no payout id, got %q", wds[0].PayoutID)
	}
}

func TestStripeWithdrawTransferFailureMarksRowFailedAndRefunded(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-w-marked", "US", "full", false)))
			return
		}
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"boom","type":"invalid_request_error"}}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-marked", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502", w.Code)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Status != "failed" {
		t.Errorf("status = %q, want failed", wds[0].Status)
	}
	if !wds[0].Refunded {
		t.Error("refunded flag should be set")
	}
	if !strings.Contains(wds[0].FailureReason, "transfer_create_failed") {
		t.Errorf("failure_reason = %q", wds[0].FailureReason)
	}
}

func TestStripeWithdrawTransferOkInstantPayoutFailRefundsFeeOnly(t *testing.T) {
	// Instant withdrawal: transfer succeeds, payouts.create fails. The funds
	// stay in the connected account (Stripe's daily auto-payout delivers via
	// the standard rail), so the principal is NOT refunded — but the instant
	// fee IS, because the user isn't getting instant delivery. Row stays at
	// "transferred" with FailureReason set.
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-tr-only", "US", "full", true)))
			return
		}
		switch r.URL.Path {
		case "/v1/transfers":
			_, _ = w.Write([]byte(`{"id":"tr_ok","amount":450,"destination":"acct_x","created":1700000000}`))
		case "/v1/payouts":
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"insufficient connected balance"}}`))
		default:
			t.Errorf("unexpected: %s", r.URL.Path)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-tr-only", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	// $5 instant → fee floor $0.50 → net $4.50 transferred.
	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusAccepted {
		t.Fatalf("got %d, want 202: %s", w.Code, w.Body.String())
	}
	// Seed $10 − gross $5 + fee refund $0.50 = $5.50. The $4.50 principal is
	// in the connected account, en route via the daily sweep.
	if bal := st.GetBalance(user.AccountID); bal != 5_500_000 {
		t.Errorf("balance = %d, want 5_500_000 (fee refunded, principal in connected acct)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if wds[0].Status != "transferred" {
		t.Errorf("status = %q, want transferred", wds[0].Status)
	}
	if wds[0].Refunded {
		t.Error("refunded flag should NOT be set (principal not refunded)")
	}
	if wds[0].TransferID != "tr_ok" {
		t.Errorf("transfer_id = %q", wds[0].TransferID)
	}
	if !strings.Contains(wds[0].FailureReason, "instant_payout_create_failed") {
		t.Errorf("failure_reason = %q", wds[0].FailureReason)
	}
	if !strings.Contains(wds[0].FailureReason, "fee refunded") {
		t.Errorf("failure_reason should note the fee refund, got %q", wds[0].FailureReason)
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

// --- Webhook ---

func TestConnectWebhookAccountUpdatedFlipsStatusToReady(t *testing.T) {
	// Use a fake Stripe server because account.updated calls don't actually
	// hit the API — Stripe sends us the object — but we still want the
	// signature verifier to be enabled.
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		t.Errorf("unexpected Stripe call: %s", r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := seedUser(t, st, "acct-wh-1", "alice@example.com")
	_ = st.SetUserStripeAccount(user.AccountID, "acct_x_wh", "pending", "", "", "", false)

	payload := []byte(`{
		"type": "account.updated",
		"account": "acct_x_wh",
		"data": {"object": {
			"id": "acct_x_wh",
			"payouts_enabled": true,
			"details_submitted": true,
			"external_accounts": {"data":[
				{"object":"bank_account","last4":"6789","default_for_currency":true}
			]}
		}}
	}`)
	req := signedConnectRequest(t, payload, "whsec_test")
	w := httptest.NewRecorder()
	srv.handleStripeConnectWebhook(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountStatus != "ready" {
		t.Errorf("status = %q, want ready", refreshed.StripeAccountStatus)
	}
	if refreshed.StripeDestinationType != "bank" {
		t.Errorf("destination_type = %q, want bank", refreshed.StripeDestinationType)
	}
	if refreshed.StripeDestinationLast4 != "6789" {
		t.Errorf("last4 = %q", refreshed.StripeDestinationLast4)
	}
}

func TestConnectWebhookPayoutFailedKeepsFundsAndDoesNotRefund(t *testing.T) {
	// payout.failed means the funds returned to the CONNECTED account's
	// balance, where Stripe's daily auto-payout retries delivery. Refunding
	// the ledger here would double-pay the user (ledger credit + eventual
	// bank payout), so the row stays "transferred" with the failure recorded.
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-wh-fail", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	// Manually create a withdrawal row mimicking what the handler would have
	// persisted, then debit the ledger to put us in the post-withdraw state.
	withdrawalID := "wd-test-1"
	_ = st.Debit(user.AccountID, 5_000_000, store.LedgerCharge, "stripe_withdraw:"+withdrawalID)
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID:              withdrawalID,
		AccountID:       user.AccountID,
		StripeAccountID: user.StripeAccountID,
		PayoutID:        "po_failtest",
		AmountMicroUSD:  5_000_000,
		FeeMicroUSD:     0,
		NetMicroUSD:     5_000_000,
		Method:          "standard",
		Status:          "transferred",
	})

	payload := []byte(`{
		"type": "payout.failed",
		"account": "` + user.StripeAccountID + `",
		"data": {"object": {
			"id": "po_failtest",
			"status": "failed",
			"amount": 500,
			"method": "standard",
			"failure_code": "account_closed",
			"failure_message": "Bank account closed"
		}}
	}`)
	req := signedConnectRequest(t, payload, "whsec_test")
	w := httptest.NewRecorder()
	srv.handleStripeConnectWebhook(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (no refund — funds retry via sweep)", bal)
	}
	wd, _ := st.GetStripeWithdrawal(withdrawalID)
	if wd.Status != "transferred" {
		t.Errorf("status = %q, want transferred (sweep will retry)", wd.Status)
	}
	if wd.Refunded {
		t.Error("refunded flag should NOT be set")
	}
	if !strings.Contains(wd.FailureReason, "account_closed") {
		t.Errorf("failure_reason = %q", wd.FailureReason)
	}
}

func TestConnectWebhookPayoutFailedNeverRefundsOnRedelivery(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-wh-idem", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")
	withdrawalID := "wd-idem-1"
	_ = st.Debit(user.AccountID, 5_000_000, store.LedgerCharge, "stripe_withdraw:"+withdrawalID)
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID: withdrawalID, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		PayoutID: "po_idem", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred",
	})

	payload := []byte(`{
		"type":"payout.failed","account":"` + user.StripeAccountID + `",
		"data":{"object":{"id":"po_idem","status":"failed","amount":500,"method":"standard","failure_code":"x","failure_message":"y"}}
	}`)

	for i := range 3 {
		req := signedConnectRequest(t, payload, "whsec_test")
		w := httptest.NewRecorder()
		srv.handleStripeConnectWebhook(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("delivery %d: got %d", i, w.Code)
		}
	}
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance after 3x payout.failed = %d, want 5_000_000 (no refunds)", bal)
	}
	wd, _ := st.GetStripeWithdrawal(withdrawalID)
	if wd.Status != "transferred" {
		t.Errorf("status = %q, want transferred", wd.Status)
	}
}

func TestConnectWebhookLegacyRefundedRowStaysTerminal(t *testing.T) {
	// Rows refunded under the pre-fix semantics must never flip back to
	// "transferred" (the sweep matcher could otherwise double-pay them).
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-wh-legacy", "alice@example.com", false)
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID: "wd-legacy-1", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		PayoutID: "po_legacy", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", Refunded: true,
	})

	payload := []byte(`{
		"type":"payout.failed","account":"` + user.StripeAccountID + `",
		"data":{"object":{"id":"po_legacy","status":"failed","amount":500,"method":"standard","failure_code":"x","failure_message":"y"}}
	}`)
	req := signedConnectRequest(t, payload, "whsec_test")
	w := httptest.NewRecorder()
	srv.handleStripeConnectWebhook(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d", w.Code)
	}

	wd, _ := st.GetStripeWithdrawal("wd-legacy-1")
	if wd.Status != "failed" {
		t.Errorf("status = %q, want failed (terminal for already-refunded rows)", wd.Status)
	}
}

// --- Sweep payout reconciliation (automatic daily payouts) ---

func TestConnectWebhookSweepPayoutPaidMarksTransferredRows(t *testing.T) {
	// Standard withdrawals have no payout ID — Stripe's automatic daily sweep
	// delivers them. When the sweep's payout.paid arrives (an ID we never
	// recorded), every "transferred" row for that connected account whose
	// funds had settled by the sweep's creation must flip to "paid". This
	// account is under the full agreement, so transfers settle immediately.
	fakeStripe := accountServingStripe("full")
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-wh-sweep", "alice@example.com", false)

	sweepTime := time.Now()
	mk := func(id string, createdAt time.Time, status string) {
		t.Helper()
		if err := st.CreateStripeWithdrawal(&store.StripeWithdrawal{
			ID: id, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
			AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
			Method: "standard", Status: status, CreatedAt: createdAt,
		}); err != nil {
			t.Fatalf("create withdrawal %s: %v", id, err)
		}
	}
	mk("wd-sw-old-1", sweepTime.Add(-48*time.Hour), "transferred")
	mk("wd-sw-old-2", sweepTime.Add(-1*time.Hour), "transferred")
	mk("wd-sw-after", sweepTime.Add(2*time.Hour), "transferred") // transferred after the sweep was cut
	mk("wd-sw-paid", sweepTime.Add(-3*time.Hour), "paid")        // already terminal

	payload := []byte(`{
		"type":"payout.paid","account":"` + user.StripeAccountID + `",
		"data":{"object":{"id":"po_sweep_unknown","status":"paid","amount":1000,"method":"standard",
			"automatic":true,"created":` + strconv.FormatInt(sweepTime.Unix(), 10) + `}}
	}`)
	req := signedConnectRequest(t, payload, "whsec_test")
	w := httptest.NewRecorder()
	srv.handleStripeConnectWebhook(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	want := map[string]string{
		"wd-sw-old-1": "paid",
		"wd-sw-old-2": "paid",
		"wd-sw-after": "transferred",
		"wd-sw-paid":  "paid",
	}
	for id, wantStatus := range want {
		wd, _ := st.GetStripeWithdrawal(id)
		if wd.Status != wantStatus {
			t.Errorf("%s: status = %q, want %q", id, wd.Status, wantStatus)
		}
	}
}

func TestConnectWebhookSweepPayoutFailedLeavesRowsAlone(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-wh-sweepfail", "alice@example.com", false)
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID: "wd-swf-1", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", CreatedAt: time.Now().Add(-2 * time.Hour),
	})

	payload := []byte(`{
		"type":"payout.failed","account":"` + user.StripeAccountID + `",
		"data":{"object":{"id":"po_sweep_fail","status":"failed","amount":500,"method":"standard",
			"automatic":true,"created":` + strconv.FormatInt(time.Now().Unix(), 10) + `,
			"failure_code":"account_closed","failure_message":"closed"}}
	}`)
	req := signedConnectRequest(t, payload, "whsec_test")
	w := httptest.NewRecorder()
	srv.handleStripeConnectWebhook(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d", w.Code)
	}

	wd, _ := st.GetStripeWithdrawal("wd-swf-1")
	if wd.Status != "transferred" {
		t.Errorf("status = %q, want transferred (sweep retries on next schedule)", wd.Status)
	}
	if wd.Refunded {
		t.Error("no ledger refund on sweep failure")
	}
}

func TestConnectWebhookPayoutPaidIsIdempotent(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-wh-paid", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")
	withdrawalID := "wd-paid-1"
	_ = st.Debit(user.AccountID, 5_000_000, store.LedgerCharge, "stripe_withdraw:"+withdrawalID)
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID: withdrawalID, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		PayoutID: "po_paid", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred",
	})

	payload := []byte(`{
		"type":"payout.paid","account":"` + user.StripeAccountID + `",
		"data":{"object":{"id":"po_paid","status":"paid","amount":500,"method":"standard"}}
	}`)
	for i := range 3 {
		req := signedConnectRequest(t, payload, "whsec_test")
		w := httptest.NewRecorder()
		srv.handleStripeConnectWebhook(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("delivery %d: got %d", i, w.Code)
		}
	}
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance shouldn't change on payout.paid; got %d, want 5_000_000", bal)
	}
	wd, _ := st.GetStripeWithdrawal(withdrawalID)
	if wd.Status != "paid" {
		t.Errorf("status = %q", wd.Status)
	}
}

func TestConnectWebhookRejectsBadSignature(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, _ := stripePayoutsTestServer(t, false, fakeStripe)

	payload := []byte(`{"type":"account.updated","data":{"object":{"id":"x"}}}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/connect/webhook", strings.NewReader(string(payload)))
	req.Header.Set("Stripe-Signature", "t=1,v1=deadbeef")
	w := httptest.NewRecorder()
	srv.handleStripeConnectWebhook(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 on bad signature", w.Code)
	}
}

// --- helpers ---

// readyUser seeds a user that has finished Stripe onboarding. instantEligible
// controls whether the destination is a debit card (true) or bank (false).
func readyUser(t *testing.T, st *store.MemoryStore, accountID, email string, instantEligible bool) *store.User {
	t.Helper()
	u := seedUser(t, st, accountID, email)
	dest := "bank"
	last4 := "6789"
	if instantEligible {
		dest = "card"
		last4 = "4242"
	}
	if err := st.SetUserStripeAccount(u.AccountID, "acct_"+accountID, "ready", "", dest, last4, instantEligible); err != nil {
		t.Fatal(err)
	}
	got, _ := st.GetUserByAccountID(u.AccountID)
	return got
}

// signedConnectRequest builds an HTTP request with a valid Stripe-Signature
// header for the given payload + secret.
func signedConnectRequest(t *testing.T, payload []byte, secret string) *http.Request {
	t.Helper()
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(ts + "." + string(payload)))
	sig := hex.EncodeToString(mac.Sum(nil))
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/connect/webhook",
		strings.NewReader(string(payload)))
	req.Header.Set("Stripe-Signature", "t="+ts+",v1="+sig)
	req.Header.Set("Content-Type", "application/json")
	return req
}

// TestStripeWithdrawRejectsExceedingWithdrawableViaDebit verifies that the
// DebitWithdrawable path rejects a withdrawal that exceeds the withdrawable
// balance even when total balance is sufficient.
func TestStripeWithdrawRejectsExceedingWithdrawableViaDebit(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-debit-guard", "guard@example.com", false)

	// $100 total but only $20 withdrawable.
	st.Credit(user.AccountID, 80_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 20_000_000, store.LedgerPayout, "earnings")

	// Try to withdraw $30 — total balance is $100 but withdrawable is only $20.
	body := `{"amount_usd":"30.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400; body: %s", w.Code, w.Body.String())
	}

	// Balances should be untouched.
	if bal := st.GetBalance(user.AccountID); bal != 100_000_000 {
		t.Errorf("balance = %d, want 100_000_000 (unchanged)", bal)
	}
	if wd := st.GetWithdrawableBalance(user.AccountID); wd != 20_000_000 {
		t.Errorf("withdrawable = %d, want 20_000_000 (unchanged)", wd)
	}
}

// TestStripeWithdrawNoInflationOnFailedPayout verifies that a failed payout
// followed by a refund does not inflate the withdrawable balance beyond its
// original value. This was the core accounting bug: Debit ate non-withdrawable
// credits, but CreditWithdrawable restored the amount as withdrawable earnings.
func TestStripeWithdrawNoInflationOnFailedPayout(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/transfers" && r.Method == http.MethodPost:
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"message":"boom","type":"invalid_request_error"}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-inflate-1", "inflate@example.com", false)

	// Seed: $100 total, $50 withdrawable (earned), $50 non-withdrawable (credits).
	st.Credit(user.AccountID, 50_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 50_000_000, store.LedgerPayout, "earnings")

	beforeBalance := st.GetBalance(user.AccountID)
	beforeWithdrawable := st.GetWithdrawableBalance(user.AccountID)
	if beforeBalance != 100_000_000 {
		t.Fatalf("initial balance = %d, want 100_000_000", beforeBalance)
	}
	if beforeWithdrawable != 50_000_000 {
		t.Fatalf("initial withdrawable = %d, want 50_000_000", beforeWithdrawable)
	}

	// Attempt a $10 withdrawal — transfer will fail, triggering refund.
	body := `{"amount_usd":"10.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	// Transfer fails → refund should restore original balances exactly.
	afterBalance := st.GetBalance(user.AccountID)
	afterWithdrawable := st.GetWithdrawableBalance(user.AccountID)

	if afterBalance != beforeBalance {
		t.Errorf("balance after failed withdrawal = %d, want %d (unchanged)", afterBalance, beforeBalance)
	}
	if afterWithdrawable != beforeWithdrawable {
		t.Errorf("withdrawable after failed withdrawal = %d, want %d (unchanged) — inflation bug!", afterWithdrawable, beforeWithdrawable)
	}
}

// silence unused-import linter when tests are pruned during iteration.
var (
	_ = io.Discard
	_ = url.QueryEscape
	_ = sync.Mutex{}
)

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

// TestStripeWithdrawAccountGonePreCheckUnlinksWithoutDebit pins that a
// withdrawal against a closed Stripe account fails BEFORE the ledger debit
// and unlinks the dead account.
func TestStripeWithdrawAccountGonePreCheckUnlinksWithoutDebit(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"message":"No such account: 'acct_acct-w-gone'","type":"invalid_request_error"}}`))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-gone", "gone@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "stripe_account_gone" {
		t.Errorf("error type = %v", errObj["type"])
	}
	// No debit happened.
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance = %d, want 10_000_000 (untouched)", bal)
	}
	// Dead account unlinked so the user can re-onboard.
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want empty after unlink", refreshed.StripeAccountID)
	}
	// No withdrawal row persisted.
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 0 {
		t.Errorf("expected no withdrawal rows, got %d", len(wds))
	}
}

// TestStripeWithdrawServiceAgreementMismatchPreCheck pins the AU/NZ/JP
// experience: withdrawing against a full-agreement account outside the
// transfer region returns an actionable "recreate" error before any debit
// and flips the local status to restricted.
func TestStripeWithdrawServiceAgreementMismatchPreCheck(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-w-au", "AU", "full", false)))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-au", "au@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "stripe_account_recreate_required" {
		t.Errorf("error type = %v", errObj["type"])
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance = %d, want 10_000_000 (untouched)", bal)
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountStatus != "restricted" {
		t.Errorf("status = %q, want restricted (prompts re-onboarding)", refreshed.StripeAccountStatus)
	}
}

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
	if got := errorTypeOf(t, w.Body.Bytes()); got != "no_stripe_account" {
		t.Errorf("error type = %q", got)
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
	if got := errorTypeOf(t, w.Body.Bytes()); got != "account_gone" {
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

// --- Unlink ---

func TestStripeUnlinkClearsAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-unlink-1", "unlink@example.com", false)

	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeUnlink(w, req)

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
	srv.handleStripeUnlink(w2, req2)
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
	srv.handleStripeUnlink(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

// --- Reconciler ---

// TestStripeReconcilerHealsManualScheduleForStuckWithdrawals pins the
// background unstick path: withdrawals stuck in "transferred" on an account
// with the legacy manual payout schedule cause the reconciler to flip the
// schedule to daily.
func TestStripeReconcilerHealsManualScheduleForStuckWithdrawals(t *testing.T) {
	var mu sync.Mutex
	var scheduleUpdates []string

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet:
			acct := strings.Replace(healthyAccountJSON("acct_stuck_1", "FR", "full", false),
				`"interval":"daily"`, `"interval":"manual"`, 1)
			_, _ = w.Write([]byte(acct))
		case strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodPost:
			mu.Lock()
			scheduleUpdates = append(scheduleUpdates, strings.TrimPrefix(r.URL.Path, "/v1/accounts/"))
			mu.Unlock()
			_, _ = w.Write([]byte(healthyAccountJSON("acct_stuck_1", "FR", "full", false)))
		default:
			t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-stuck-user", "stuck@example.com", false)
	// Stuck for 3 days — like the €10.57 sitting in a manual-schedule account.
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID: "wd-stuck-1", AccountID: user.AccountID, StripeAccountID: "acct_stuck_1",
		TransferID: "tr_stuck_1", AmountMicroUSD: 10_570_000, NetMicroUSD: 10_570_000,
		Method: "standard", Status: "transferred", CreatedAt: time.Now().Add(-72 * time.Hour),
	})
	// A fresh transferred row must NOT trigger reconciliation.
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID: "wd-fresh-1", AccountID: user.AccountID, StripeAccountID: "acct_fresh_ok",
		TransferID: "tr_fresh_1", AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Status: "transferred", CreatedAt: time.Now().Add(-1 * time.Hour),
	})

	srv.sweepStuckStripeWithdrawals()

	mu.Lock()
	defer mu.Unlock()
	if len(scheduleUpdates) != 1 || scheduleUpdates[0] != "acct_stuck_1" {
		t.Errorf("schedule updates = %v, want [acct_stuck_1]", scheduleUpdates)
	}
}

// TestStripeWithdrawAgreementMismatchWithOmittedField pins the REAL Stripe
// API shape, verified against the live platform: accounts under the full
// agreement OMIT tos_acceptance.service_agreement entirely (only date/ip are
// present). The mismatch detection must normalize the absent field to "full"
// — treating it as unknown silently skipped every broken AU/NZ/JP account.
func TestStripeWithdrawAgreementMismatchWithOmittedField(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			// Verbatim shape of a live AU full-agreement Express account.
			_, _ = w.Write([]byte(`{
				"id": "acct_acct-w-au-real",
				"country": "AU",
				"default_currency": "aud",
				"payouts_enabled": true,
				"details_submitted": true,
				"tos_acceptance": {"date": 1782738707},
				"capabilities": {"card_payments": "active", "transfers": "active"},
				"settings": {"payouts": {"schedule": {"delay_days": 2, "interval": "manual"}}},
				"external_accounts": {"data": [{"object":"bank_account","last4":"6789","default_for_currency":true}]}
			}`))
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodPost {
			// Schedule self-heal fires for the manual interval — accept it.
			_, _ = w.Write([]byte(`{"id":"acct_acct-w-au-real"}`))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-au-real", "au-real@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409 (absent service_agreement must normalize to full): %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "stripe_account_recreate_required" {
		t.Errorf("error type = %v", errObj["type"])
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance = %d, want untouched", bal)
	}
}
