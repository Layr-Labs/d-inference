package billing

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

	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// stripePayoutsTestServer wires up a controller fixture with an in-memory store and a
// billing service whose Stripe Connect client points at the supplied fake
// Stripe HTTP server. Pass mockMode=true to bypass Stripe entirely.
func stripePayoutsTestServer(t *testing.T, mockMode bool, fakeStripe *httptest.Server, opts ...billingservice.Config) (*controllerFixture, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})

	srv := newControllerFixture(st, logger)

	cfg := billingservice.Config{
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
	srv.SetBilling(billingservice.NewService(st, ledger, logger, cfg))
	return srv, st
}

// setStripeAPIBase swaps billing.stripeAPIBase to point at our fake server,
// returning a cleanup func to restore it.
func setStripeAPIBase(url string) func() {
	prev := billingservice.SetStripeAPIBaseForTest(url)
	return func() { billingservice.SetStripeAPIBaseForTest(prev) }
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

// silence unused-import linter when tests are pruned during iteration.
var (
	_ = io.Discard
	_ = url.QueryEscape
	_ = sync.Mutex{}
)

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
