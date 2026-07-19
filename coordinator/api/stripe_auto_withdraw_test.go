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
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestNextStripeAutoWithdrawAt(t *testing.T) {
	tests := []struct {
		name string
		in   time.Time
		want time.Time
	}{
		{
			name: "before weekly slot",
			in:   time.Date(2026, time.July, 20, 8, 59, 0, 0, time.UTC),
			want: time.Date(2026, time.July, 20, 9, 0, 0, 0, time.UTC),
		},
		{
			name: "at weekly slot moves to next week",
			in:   time.Date(2026, time.July, 20, 9, 0, 0, 0, time.UTC),
			want: time.Date(2026, time.July, 27, 9, 0, 0, 0, time.UTC),
		},
		{
			name: "midweek",
			in:   time.Date(2026, time.July, 22, 17, 30, 0, 0, time.UTC),
			want: time.Date(2026, time.July, 27, 9, 0, 0, 0, time.UTC),
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := nextStripeAutoWithdrawAt(tc.in); !got.Equal(tc.want) {
				t.Fatalf("next = %s, want %s", got, tc.want)
			}
		})
	}
}

func TestStripeAutoWithdrawPreferenceRequiresReadyAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-auto-pref-not-ready", "alice@example.com")
	req := httptest.NewRequest(http.MethodPut, "/v1/billing/stripe/auto-withdraw",
		strings.NewReader(`{"enabled":true}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()

	srv.handleStripeAutoWithdraw(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409: %s", w.Code, w.Body.String())
	}
	got, _ := st.GetUserByAccountID(user.AccountID)
	if got.StripeAutoWithdrawEnabled {
		t.Fatal("preference enabled without a ready Stripe account")
	}
}

func TestStripeAutoWithdrawPreferenceEnableDisable(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-auto-pref-ready", "alice@example.com", false)

	req := httptest.NewRequest(http.MethodPut, "/v1/billing/stripe/auto-withdraw",
		strings.NewReader(`{"enabled":true}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeAutoWithdraw(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("enable status = %d: %s", w.Code, w.Body.String())
	}
	var enabled map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &enabled); err != nil {
		t.Fatal(err)
	}
	if enabled["auto_withdraw_enabled"] != true || enabled["auto_withdraw_next_at"] == nil {
		t.Fatalf("enable response = %v", enabled)
	}

	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	req = httptest.NewRequest(http.MethodPut, "/v1/billing/stripe/auto-withdraw",
		strings.NewReader(`{"enabled":false}`))
	req = withPrivyUser(req, refreshed)
	w = httptest.NewRecorder()
	srv.handleStripeAutoWithdraw(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("disable status = %d: %s", w.Code, w.Body.String())
	}
	refreshed, _ = st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAutoWithdrawEnabled || refreshed.StripeAutoWithdrawNextAt != nil {
		t.Fatalf("disable did not clear active authorization: %+v", refreshed)
	}
}

func TestStripePayoutRoutesRejectInferenceAPIKeys(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-auto-route-auth", "alice@example.com", false)
	key, err := st.CreateKeyForAccount(user.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	for _, tc := range []struct {
		method string
		path   string
		body   string
	}{
		{http.MethodPost, "/v1/billing/stripe/onboard", `{"country":"US"}`},
		{http.MethodGet, "/v1/billing/stripe/status", ""},
		{http.MethodPost, "/v1/billing/withdraw/stripe", `{"amount_usd":"1.00"}`},
		{http.MethodGet, "/v1/billing/stripe/withdrawals", ""},
		{http.MethodPut, "/v1/billing/stripe/auto-withdraw", `{"enabled":true}`},
		{http.MethodDelete, "/v1/billing/stripe/account", ""},
	} {
		req, err := http.NewRequest(tc.method, ts.URL+tc.path, strings.NewReader(tc.body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+key)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = res.Body.Close()
		if res.StatusCode != http.StatusForbidden {
			t.Errorf("%s %s status = %d, want 403", tc.method, tc.path, res.StatusCode)
		}
	}
}

func TestStripeAutoWithdrawCanBeDisabledWhenStripeIsUnavailable(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-auto-disable-outage", "alice@example.com", false)
	now := time.Now().UTC()
	if err := st.SetStripeAutoWithdraw(
		user.AccountID, user.StripeAccountID, true, now, now.Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	srv.SetBilling(nil)
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(http.MethodPut, "/v1/billing/stripe/auto-withdraw",
		strings.NewReader(`{"enabled":false}`))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeAutoWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("disable status = %d: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAutoWithdrawEnabled {
		t.Fatal("Stripe outage prevented authorization revocation")
	}
}

func TestStripeStatusRefreshReturnsRevokedAutoWithdrawState(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"error":{"type":"invalid_request_error","message":"No such account: 'acct_gone'"}}`)
	}))
	t.Cleanup(fakeStripe.Close)
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-auto-status-gone", "alice@example.com", false)
	now := time.Now().UTC()
	if err := st.SetStripeAutoWithdraw(
		user.AccountID, user.StripeAccountID, true, now, now.Add(time.Hour),
	); err != nil {
		t.Fatal(err)
	}
	user, _ = st.GetUserByAccountID(user.AccountID)

	req := httptest.NewRequest(
		http.MethodGet, "/v1/billing/stripe/status?refresh=1", nil,
	)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeStatus(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var response map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response["has_account"] != false || response["auto_withdraw_enabled"] != false {
		t.Fatalf("contradictory refreshed status: %v", response)
	}
}

func TestStripeAutoWithdrawWorkerTransfersFullBalanceOnce(t *testing.T) {
	fakeStripe, calls := newAutoWithdrawStripeServer(t)
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-auto-worker", "alice@example.com", false)
	if err := st.CreditWithdrawable(user.AccountID, 12_345_678, store.LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	slot := now.Add(-time.Minute)
	if err := st.SetStripeAutoWithdraw(user.AccountID, user.StripeAccountID, true, now.Add(-time.Hour), slot); err != nil {
		t.Fatal(err)
	}

	srv.sweepStripeAutoWithdrawals(now)

	rows, err := st.ListStripeWithdrawals(user.AccountID, 10)
	if err != nil || len(rows) != 1 {
		t.Fatalf("withdrawals = %+v, err = %v", rows, err)
	}
	wd := rows[0]
	if wd.Source != store.StripeWithdrawalSourceAutomatic || wd.Status != "transferred" ||
		wd.AmountMicroUSD != 12_345_678 || wd.ScheduledFor == nil || !wd.ScheduledFor.Equal(slot) {
		t.Fatalf("withdrawal = %+v", wd)
	}
	if balance := st.GetWithdrawableBalance(user.AccountID); balance != 0 {
		t.Fatalf("withdrawable balance = %d, want 0", balance)
	}
	if got := calls.snapshot(); got.count != 1 || got.amountCents != "1234" ||
		got.idempotencyKey != "wd-tr-"+wd.ID {
		t.Fatalf("Stripe transfer calls = %+v", got)
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAutoWithdrawNextAt == nil ||
		!refreshed.StripeAutoWithdrawNextAt.After(now) {
		t.Fatalf("next schedule was not advanced: %+v", refreshed)
	}

	// The advanced schedule and deterministic withdrawal ID prevent a second
	// debit/transfer in the same weekly slot.
	srv.sweepStripeAutoWithdrawals(now)
	if got := calls.snapshot(); got.count != 1 {
		t.Fatalf("duplicate sweep made %d Stripe transfers", got.count)
	}
}

func TestStripeAutoWithdrawWorkerResumesDebitAfterOptOut(t *testing.T) {
	fakeStripe, calls := newAutoWithdrawStripeServer(t)
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-auto-resume", "alice@example.com", false)
	if err := st.CreditWithdrawable(user.AccountID, 5_000_000, store.LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	slot := now.Add(-time.Minute)
	if err := st.SetStripeAutoWithdraw(user.AccountID, user.StripeAccountID, true, now.Add(-time.Hour), slot); err != nil {
		t.Fatal(err)
	}
	id := automaticStripeWithdrawalID(user.AccountID, slot)
	wd := &store.StripeWithdrawal{
		ID: id, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "pending",
	}
	if err := st.CreateStripeAutoWithdrawalWithDebit(
		wd, store.LedgerStripePayout, "stripe_withdraw:"+id, slot,
	); err != nil {
		t.Fatal(err)
	}
	if err := st.SetStripeAutoWithdraw(user.AccountID, user.StripeAccountID, false, now, time.Time{}); err != nil {
		t.Fatal(err)
	}

	srv.sweepStripeAutoWithdrawals(now)

	stored, err := st.GetStripeWithdrawal(id)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Status != "transferred" || stored.TransferID == "" {
		t.Fatalf("pending authorized debit was not resumed: %+v", stored)
	}
	if got := calls.snapshot(); got.count != 1 {
		t.Fatalf("resume made %d Stripe transfers, want 1", got.count)
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAutoWithdrawEnabled {
		t.Fatal("resuming an in-flight withdrawal re-enabled the preference")
	}
}

func TestStripeAutoWithdrawWorkerDoesNotReplayExpiredIdempotencyKey(t *testing.T) {
	fakeStripe, calls := newAutoWithdrawStripeServer(t)
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-auto-expired", "alice@example.com", false)
	if err := st.CreditWithdrawable(user.AccountID, 5_000_000, store.LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	slot := now.Add(-24 * time.Hour)
	if err := st.SetStripeAutoWithdraw(
		user.AccountID, user.StripeAccountID, true, now.Add(-25*time.Hour), slot,
	); err != nil {
		t.Fatal(err)
	}
	id := automaticStripeWithdrawalID(user.AccountID, slot)
	createdAt := now.Add(-stripeAutoWithdrawResumeWindow - time.Minute)
	wd := &store.StripeWithdrawal{
		ID: id, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "pending", CreatedAt: createdAt, UpdatedAt: createdAt,
	}
	if err := st.CreateStripeAutoWithdrawalWithDebit(
		wd, store.LedgerStripePayout, "stripe_withdraw:"+id, slot,
	); err != nil {
		t.Fatal(err)
	}

	srv.sweepStripeAutoWithdrawals(now)

	if got := calls.snapshot(); got.count != 0 {
		t.Fatalf("expired idempotency key was replayed %d time(s)", got.count)
	}
	stored, _ := st.GetStripeWithdrawal(id)
	if stored.Status != "pending" || stored.TransferID != "" {
		t.Fatalf("expired row was mutated: %+v", stored)
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAutoWithdrawNextAt == nil ||
		!refreshed.StripeAutoWithdrawNextAt.After(now) {
		t.Fatalf("expired slot was not advanced to avoid starvation: %+v", refreshed)
	}
}

type autoWithdrawStripeCalls struct {
	mu             sync.Mutex
	count          int
	amountCents    string
	idempotencyKey string
}

type autoWithdrawStripeCallSnapshot struct {
	count          int
	amountCents    string
	idempotencyKey string
}

func (c *autoWithdrawStripeCalls) snapshot() autoWithdrawStripeCallSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()
	return autoWithdrawStripeCallSnapshot{
		count:          c.count,
		amountCents:    c.amountCents,
		idempotencyKey: c.idempotencyKey,
	}
}

func newAutoWithdrawStripeServer(t *testing.T) (*httptest.Server, *autoWithdrawStripeCalls) {
	t.Helper()
	calls := &autoWithdrawStripeCalls{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/accounts/"):
			id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, healthyAccountJSON(id, "US", "full", false))
		case r.Method == http.MethodPost && r.URL.Path == "/v1/transfers":
			body, _ := io.ReadAll(r.Body)
			values, _ := url.ParseQuery(string(body))
			calls.mu.Lock()
			calls.count++
			calls.amountCents = values.Get("amount")
			calls.idempotencyKey = r.Header.Get("Idempotency-Key")
			calls.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"id":"tr_auto_1","amount":1234,"destination":"acct_auto"}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	return server, calls
}
