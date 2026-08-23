package api

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
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
	if len(opts) > 1 {
		t.Fatalf("stripePayoutsTestServer accepts at most one billing config override")
	}
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
	got, err := st.GetUserByAccountID(accountID)
	if err != nil {
		t.Fatalf("load created user: %v", err)
	}
	return got
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
	got, err := st.GetUserByAccountID(u.AccountID)
	if err != nil {
		t.Fatalf("load Stripe-ready user: %v", err)
	}
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


// mkWithdrawal seeds a withdrawal row directly in the store.
func mkWithdrawal(t *testing.T, st *store.MemoryStore, wd store.StripeWithdrawal) {
	t.Helper()
	if wd.CreatedAt.IsZero() {
		wd.CreatedAt = time.Now().Add(-2 * time.Hour)
	}
	if err := st.CreateStripeWithdrawal(&wd); err != nil {
		t.Fatalf("create withdrawal %s: %v", wd.ID, err)
	}
}


func payoutEventPayload(payoutID, account, status string, automatic bool, created int64) []byte {
	eventType := "payout.paid"
	if status != "paid" {
		eventType = "payout.failed"
	}
	return []byte(`{
		"type":"` + eventType + `","account":"` + account + `",
		"data":{"object":{"id":"` + payoutID + `","status":"` + status + `","amount":450,"method":"standard",
			"automatic":` + strconv.FormatBool(automatic) + `,"created":` + strconv.FormatInt(created, 10) + `,
			"failure_code":"could_not_process","failure_message":"bank rejected"}}
	}`)
}


func deliverConnectWebhook(t *testing.T, srv *Server, payload []byte) *httptest.ResponseRecorder {
	t.Helper()
	req := signedConnectRequest(t, payload, "whsec_test")
	w := httptest.NewRecorder()
	srv.handleStripeConnectWebhook(w, req)
	return w
}
