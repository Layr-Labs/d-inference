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

	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// stripePayoutsTestServer wires up a Server with an in-memory store and a
// billing service whose Stripe Connect client points at the supplied fake
// Stripe HTTP server. Pass mockMode=true to bypass Stripe entirely.
func stripePayoutsTestServer(t *testing.T, mockMode bool, fakeStripe *httptest.Server, opts ...billing.Config) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

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
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{}`))
	w := httptest.NewRecorder()
	srv.handleStripeOnboard(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}

func TestStripeOnboardCreatesAccountAndPersistsID(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-onboard-1", "alice@example.com")

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{}`))
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

func TestStripeOnboardDefaultsToUSWhenNoCountry(t *testing.T) {
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
			_, _ = w.Write([]byte(`{"id":"acct_us_test","type":"express","charges_enabled":false,"payouts_enabled":false,"details_submitted":false}`))
		case strings.HasPrefix(r.URL.Path, "/v1/account_links"):
			w.WriteHeader(200)
			_, _ = w.Write([]byte(`{"url":"https://connect.stripe.com/setup/e/us_test"}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := seedUser(t, st, "acct-country-2", "bob@example.com")

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard",
		strings.NewReader(`{}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeOnboard(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	mu.Lock()
	got := accountCreateBody.Get("country")
	mu.Unlock()
	if got != "US" {
		t.Errorf("country sent to Stripe = %q, want US (platform default)", got)
	}
}

func TestStripeOnboardReusesExistingAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-reuse-1", "bob@example.com")

	// Pre-seed an existing Stripe account ID.
	_ = st.SetUserStripeAccount(user.AccountID, "acct_existing_123", "ready", "bank", "1234", false)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/onboard", strings.NewReader(`{}`))
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

// --- Status ---

func TestStripeStatusReportsCurrentState(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-status-1", "alice@example.com")
	_ = st.SetUserStripeAccount(user.AccountID, "acct_x", "ready", "card", "4242", true)
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
	st := store.NewMemory("test-key")

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
		if r.URL.Path == "/v1/payouts" {
			_, _ = w.Write([]byte(`{"id":"po_pers","amount":500,"method":"standard","status":"in_transit","arrival_date":1700000300}`))
			return
		}
		t.Errorf("unexpected Stripe call: %s", r.URL.Path)
	}))
	defer fakeStripe.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
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

	// Final state.
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Status != "transferred" {
		t.Errorf("final status = %q, want transferred", wds[0].Status)
	}
	if wds[0].TransferID != "tr_pers" || wds[0].PayoutID != "po_pers" {
		t.Errorf("transfer/payout ids not persisted: %+v", wds[0])
	}
}

func TestStripeWithdrawTransferFailureMarksRowFailedAndRefunded(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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

func TestStripeWithdrawTransferOkPayoutFailLeavesRowTransferred(t *testing.T) {
	// Transfer succeeds, payout fails — we keep the funds in the connected
	// account (Stripe's auto-payout schedule will move them) and DON'T
	// refund the user. Row stays at "transferred" with FailureReason set.
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/transfers":
			_, _ = w.Write([]byte(`{"id":"tr_ok","amount":500,"destination":"acct_x","created":1700000000}`))
		case "/v1/payouts":
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"insufficient connected balance"}}`))
		default:
			t.Errorf("unexpected: %s", r.URL.Path)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-tr-only", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusAccepted {
		t.Fatalf("got %d, want 202: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (no refund — funds in connected acct)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if wds[0].Status != "transferred" {
		t.Errorf("status = %q, want transferred", wds[0].Status)
	}
	if wds[0].Refunded {
		t.Error("refunded flag should NOT be set")
	}
	if wds[0].TransferID != "tr_ok" {
		t.Errorf("transfer_id = %q", wds[0].TransferID)
	}
	if !strings.Contains(wds[0].FailureReason, "payout_create_failed") {
		t.Errorf("failure_reason = %q", wds[0].FailureReason)
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

	body := `{"return_url":"http://localhost:3000/billing"}`
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
	_ = st.SetUserStripeAccount(user.AccountID, "acct_x_wh", "pending", "", "", false)

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

func TestConnectWebhookPayoutFailedRefundsLedger(t *testing.T) {
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

	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance after refund = %d, want 10_000_000", bal)
	}
	wd, _ := st.GetStripeWithdrawal(withdrawalID)
	if wd.Status != "failed" {
		t.Errorf("status = %q, want failed", wd.Status)
	}
	if !wd.Refunded {
		t.Error("refunded flag should be set")
	}
	if !strings.Contains(wd.FailureReason, "account_closed") {
		t.Errorf("failure_reason = %q", wd.FailureReason)
	}
}

func TestConnectWebhookPayoutFailedIsIdempotent(t *testing.T) {
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
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance after 3x payout.failed = %d, want 10_000_000 (single refund)", bal)
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
	if err := st.SetUserStripeAccount(u.AccountID, "acct_"+accountID, "ready", dest, last4, instantEligible); err != nil {
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

// silence unused-import linter when tests are pruned during iteration.
var (
	_ = io.Discard
	_ = url.QueryEscape
	_ = sync.Mutex{}
)
