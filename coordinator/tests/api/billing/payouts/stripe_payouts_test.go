package payouts_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/billing/payouts"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// stripePayoutsTestServer wires up a Server with an in-memory store and a
// billing service whose Stripe Connect client points at the supplied fake
// Stripe HTTP server. Pass mockMode=true to bypass Stripe entirely.
func stripePayoutsTestServer(t *testing.T, mockMode bool, fakeStripe *httptest.Server, opts ...billing.Config) (*payoutFixture, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	srv := &payoutFixture{Owner: production.New(nil, logger), logger: logger}

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
	srv.SetService(billing.NewService(st, ledger, logger, cfg))
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
func seedUser(t *testing.T, st *memory.MemoryStore, accountID, email string) *store.User {
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
func readyUser(t *testing.T, st *memory.MemoryStore, accountID, email string, instantEligible bool) *store.User {
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

// silence unused-import linter when tests are pruned during iteration.
var (
	_ = io.Discard
	_ = url.QueryEscape
	_ = sync.Mutex{}
)

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
		{"pending", http.StatusConflict},
		{"ready", http.StatusOK},
		{"restricted", http.StatusOK},
		{"rejected", http.StatusOK},
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
			srv.HandleStripeDashboardLink(w, req)

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
	seedWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-stuck-1", AccountID: user.AccountID, StripeAccountID: "acct_stuck_1",
		TransferID: "tr_stuck_1", AmountMicroUSD: 10_570_000, NetMicroUSD: 10_570_000,
		Method: "standard", Status: "transferred", CreatedAt: time.Now().Add(-72 * time.Hour),
	})
	// A fresh transferred row must NOT trigger reconciliation.
	seedWithdrawal(t, st, store.StripeWithdrawal{
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
