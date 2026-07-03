package api

// Regression tests for the PR-review fixes on the Stripe payout state
// machine: paid-terminal guards, instant-fee refunds on async payout
// failure, fee-aware transfer-reversal refunds, sweep-matcher eligibility,
// transient-store-error handling, schedule-heal abort, and unlink auth.

import (
	"errors"
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

// TestConnectWebhookPayoutFailedAfterPaidStaysPaid: a redelivered or
// out-of-order payout.failed must not flip an already-paid withdrawal back to
// "transferred" (which would strand it) — paid is terminal.
func TestConnectWebhookPayoutFailedAfterPaidStaysPaid(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-paid-term", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-paid-term", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "paid", TransferID: "tr_pt", PayoutID: "po_pt",
	})
	balBefore := st.GetBalance(user.AccountID)

	w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_pt", user.StripeAccountID, "failed", false, time.Now().Unix()))
	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	wd, _ := st.GetStripeWithdrawal("wd-paid-term")
	if wd.Status != "paid" {
		t.Errorf("status = %q, want paid (terminal)", wd.Status)
	}
	if wd.FeeRefunded {
		t.Error("fee must not be refunded for a paid withdrawal")
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore {
		t.Errorf("balance moved on a terminal row: %d -> %d", balBefore, bal)
	}
}

// TestConnectWebhookInstantPayoutFailedRefundsFeeAndDetaches: when an instant
// payout fails after creation, the user gets standard delivery via the sweep
// — so the instant fee is refunded (exactly once) and the dead payout ID is
// detached so the sweep matcher can complete the row.
func TestConnectWebhookInstantPayoutFailedRefundsFeeAndDetaches(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-async-fee", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-async-fee", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "transferred", TransferID: "tr_af", PayoutID: "po_af",
	})
	balBefore := st.GetBalance(user.AccountID)

	payload := payoutEventPayload("po_af", user.StripeAccountID, "failed", false, time.Now().Unix())
	if w := deliverConnectWebhook(t, srv, payload); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	wd, _ := st.GetStripeWithdrawal("wd-async-fee")
	if wd.Status != "transferred" {
		t.Errorf("status = %q, want transferred (sweep delivers)", wd.Status)
	}
	if !wd.FeeRefunded {
		t.Error("FeeRefunded should be set")
	}
	if wd.PayoutID != "" {
		t.Errorf("payout ID should be detached, got %q", wd.PayoutID)
	}
	if !strings.Contains(wd.FailureReason, "po_af") {
		t.Errorf("failure reason should record the failed payout id, got %q", wd.FailureReason)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore+500_000 {
		t.Errorf("balance = %d, want %d (fee refunded once)", bal, balBefore+500_000)
	}

	// Redelivery of the same event must not double-credit: the payout ID no
	// longer matches a row, and the payout is not automatic, so it's a no-op.
	if w := deliverConnectWebhook(t, srv, payload); w.Code != http.StatusOK {
		t.Fatalf("redelivery got %d", w.Code)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore+500_000 {
		t.Errorf("redelivery double-credited: balance = %d", bal)
	}
}

// TestConnectWebhookSweepSkipsRowsWithInFlightPayout: the sweep matcher must
// not claim withdrawals that have their own instant payout still in flight —
// that payout may yet fail.
func TestConnectWebhookSweepSkipsRowsWithInFlightPayout(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-sweep-skip", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-standard", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_std",
	})
	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-instant-inflight", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "transferred", TransferID: "tr_inf", PayoutID: "po_inflight",
	})

	w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_sweep_x", user.StripeAccountID, "paid", true, time.Now().Add(time.Hour).Unix()))
	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	std, _ := st.GetStripeWithdrawal("wd-standard")
	if std.Status != "paid" {
		t.Errorf("standard row = %q, want paid", std.Status)
	}
	inflight, _ := st.GetStripeWithdrawal("wd-instant-inflight")
	if inflight.Status != "transferred" {
		t.Errorf("in-flight instant row = %q, want transferred (its own webhook drives it)", inflight.Status)
	}
}

// TestConnectWebhookNonAutomaticPayoutDoesNotReconcile: a dashboard/API
// payout we didn't create must not blanket-mark rows paid — only Stripe's
// automatic sweep payouts reconcile by account.
func TestConnectWebhookNonAutomaticPayoutDoesNotReconcile(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-manual-po", "alice@example.com", false)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-manual-po", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_mp",
	})

	w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_dashboard", user.StripeAccountID, "paid", false, time.Now().Add(time.Hour).Unix()))
	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	wd, _ := st.GetStripeWithdrawal("wd-manual-po")
	if wd.Status != "transferred" {
		t.Errorf("status = %q, want transferred (non-automatic payouts don't reconcile)", wd.Status)
	}
}

func transferReversedPayload(transferID string) []byte {
	return []byte(`{
		"type":"transfer.reversed","account":"",
		"data":{"object":{"id":"` + transferID + `","amount":450,"reversed":true}}
	}`)
}

// TestConnectWebhookTransferReversedNetsOutRefundedFee: if the instant fee
// was already credited back (instant payout fell through), a later
// transfer.reversed must refund gross − fee, not gross — otherwise the user
// is paid the fee twice. The fee credit is deduped on its ledger reference.
func TestConnectWebhookTransferReversedNetsOutRefundedFee(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-rev-fee", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-rev-fee", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "transferred", TransferID: "tr_rev",
		FeeRefunded: true, // fee credited when the instant payout fell through…
	})
	// …which in production wrote this ledger entry — the dedup key.
	if err := st.CreditWithdrawable(user.AccountID, 500_000, store.LedgerRefund,
		"stripe_withdraw_fee:wd-rev-fee"); err != nil {
		t.Fatal(err)
	}
	balBefore := st.GetBalance(user.AccountID)

	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_rev")); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	wd, _ := st.GetStripeWithdrawal("wd-rev-fee")
	if wd.Status != "failed" || !wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want failed/true", wd.Status, wd.Refunded)
	}
	// Refund is gross − fee = 4_500_000, NOT the full 5_000_000.
	if bal := st.GetBalance(user.AccountID); bal != balBefore+4_500_000 {
		t.Errorf("balance = %d, want %d (gross minus already-refunded fee)", bal, balBefore+4_500_000)
	}
}

// TestConnectWebhookTransferReversedRefundsGrossWhenFeeNotRefunded: with no
// prior fee refund, a reversal refunds the full gross (net + fee parts).
func TestConnectWebhookTransferReversedRefundsGrossWhenFeeNotRefunded(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-rev-gross", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-rev-gross", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "transferred", TransferID: "tr_rev_g",
	})
	balBefore := st.GetBalance(user.AccountID)

	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_rev_g")); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore+5_000_000 {
		t.Errorf("balance = %d, want %d (full gross)", bal, balBefore+5_000_000)
	}

	// Redelivery is a no-op: row is Refunded, credits are reference-deduped.
	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_rev_g")); w.Code != http.StatusOK {
		t.Fatalf("redelivery got %d", w.Code)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore+5_000_000 {
		t.Errorf("redelivery double-credited: balance = %d", bal)
	}
}

// TestConnectWebhookTransferReversedOnPaidRowNeedsHuman: a reversal landing
// on an already-paid withdrawal (bank payout completed, then clawback) is
// ambiguous — never auto-refund, leave the row paid for manual review.
func TestConnectWebhookTransferReversedOnPaidRowNeedsHuman(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-rev-paid", "alice@example.com", false)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-rev-paid", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "paid", TransferID: "tr_rev_p",
	})
	balBefore := st.GetBalance(user.AccountID)

	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_rev_p")); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	wd, _ := st.GetStripeWithdrawal("wd-rev-paid")
	if wd.Status != "paid" || wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want paid/false (manual review)", wd.Status, wd.Refunded)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore {
		t.Errorf("balance moved on a paid row: %d -> %d", balBefore, bal)
	}
}

// flakyPayoutStore wraps MemoryStore and injects transient (non-ErrNotFound)
// failures into specific operations.
type flakyPayoutStore struct {
	*store.MemoryStore
	failLookups bool
	failUpdates bool
}

func (f *flakyPayoutStore) GetStripeWithdrawalByPayoutID(payoutID string) (*store.StripeWithdrawal, error) {
	if f.failLookups {
		return nil, errors.New("connection reset by peer")
	}
	return f.MemoryStore.GetStripeWithdrawalByPayoutID(payoutID)
}

func (f *flakyPayoutStore) UpdateStripeWithdrawal(wd *store.StripeWithdrawal) error {
	if f.failUpdates {
		return errors.New("connection reset by peer")
	}
	return f.MemoryStore.UpdateStripeWithdrawal(wd)
}

// newFlakyPayoutServer wires a Server + billing around a flakyPayoutStore.
func newFlakyPayoutServer(t *testing.T, fakeStripe *httptest.Server) (*Server, *flakyPayoutStore) {
	t.Helper()
	mem := store.NewMemory(store.Config{AdminKey: "test-key"})
	flaky := &flakyPayoutStore{MemoryStore: mem}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, flaky, ServerConfig{}, logger)
	t.Cleanup(setStripeAPIBase(fakeStripe.URL))
	ledger := payments.NewLedger(flaky)
	srv.SetBilling(billing.NewService(flaky, ledger, logger, billing.Config{
		StripeSecretKey:              "sk_test_fake",
		StripeConnectWebhookSecret:   "whsec_test",
		StripeConnectReturnURL:       "https://app.test/billing",
		StripeConnectRefreshURL:      "https://app.test/billing",
		StripeConnectPlatformCountry: "US",
	}))
	return srv, flaky
}

// TestConnectWebhookTransferReversedConvergesAcrossPersistFailure: the credit
// lands but the row persist fails → 500 → Stripe redelivers → the
// reference-deduped credit no-ops and the persist completes. Exactly one
// refund, terminal row.
func TestConnectWebhookTransferReversedConvergesAcrossPersistFailure(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, flaky := newFlakyPayoutServer(t, fakeStripe)
	user := readyUser(t, flaky.MemoryStore, "acct-rev-conv", "alice@example.com", false)

	mkWithdrawal(t, flaky.MemoryStore, store.StripeWithdrawal{
		ID: "wd-rev-conv", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_conv",
	})
	balBefore := flaky.GetBalance(user.AccountID)

	flaky.failUpdates = true
	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_conv")); w.Code != http.StatusInternalServerError {
		t.Fatalf("got %d, want 500 (persist failed — Stripe must redeliver)", w.Code)
	}
	if bal := flaky.GetBalance(user.AccountID); bal != balBefore+5_000_000 {
		t.Fatalf("credit should have landed once: balance = %d", bal)
	}

	flaky.failUpdates = false
	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_conv")); w.Code != http.StatusOK {
		t.Fatalf("redelivery got %d", w.Code)
	}
	if bal := flaky.GetBalance(user.AccountID); bal != balBefore+5_000_000 {
		t.Errorf("redelivery double-credited: balance = %d", bal)
	}
	wd, _ := flaky.GetStripeWithdrawal("wd-rev-conv")
	if wd.Status != "failed" || !wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want failed/true", wd.Status, wd.Refunded)
	}
}

// TestConnectWebhookTransientLookupErrorReturns500: a transient store failure
// on the payout lookup must NOT fall through to account-wide sweep
// reconciliation (which could claim unrelated rows) — it responds non-2xx so
// Stripe redelivers.
func TestConnectWebhookTransientLookupErrorReturns500(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, flaky := newFlakyPayoutServer(t, fakeStripe)
	flaky.failLookups = true
	mem := flaky.MemoryStore
	user := readyUser(t, mem, "acct-flaky", "alice@example.com", false)

	// An unrelated transferred row that blanket reconciliation would claim.
	mkWithdrawal(t, mem, store.StripeWithdrawal{
		ID: "wd-flaky-unrelated", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_fl",
	})

	w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_known", user.StripeAccountID, "paid", true, time.Now().Add(time.Hour).Unix()))
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("got %d, want 500 (Stripe must redeliver)", w.Code)
	}
	wd, _ := mem.GetStripeWithdrawal("wd-flaky-unrelated")
	if wd.Status != "transferred" {
		t.Errorf("unrelated row = %q, want transferred (no blanket reconcile on transient error)", wd.Status)
	}

	// Once the store recovers, redelivery reconciles normally.
	flaky.failLookups = false
	w = deliverConnectWebhook(t, srv,
		payoutEventPayload("po_known", user.StripeAccountID, "paid", true, time.Now().Add(time.Hour).Unix()))
	if w.Code != http.StatusOK {
		t.Fatalf("recovery delivery got %d", w.Code)
	}
	wd, _ = mem.GetStripeWithdrawal("wd-flaky-unrelated")
	if wd.Status != "paid" {
		t.Errorf("after recovery = %q, want paid", wd.Status)
	}
}

// TestStripeWithdrawAbortsWhenScheduleHealFails: a legacy manual-schedule
// account whose heal-to-daily update fails must abort BEFORE the ledger
// debit — standard delivery depends entirely on the daily sweep.
func TestStripeWithdrawAbortsWhenScheduleHealFails(t *testing.T) {
	manualAccountJSON := strings.Replace(
		healthyAccountJSON("acct_acct-heal-fail", "US", "full", false),
		`"interval":"daily"`, `"interval":"manual"`, 1)
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") {
			if r.Method == http.MethodGet {
				_, _ = w.Write([]byte(manualAccountJSON))
				return
			}
			// The heal (POST /v1/accounts/{id}) fails.
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":{"message":"api unavailable"}}`))
			return
		}
		t.Errorf("unexpected Stripe call after failed heal: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-heal-fail", "alice@example.com", false)
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
		t.Errorf("balance = %d, want 10_000_000 (no debit before abort)", bal)
	}
	if wds, _ := st.ListStripeWithdrawals(user.AccountID, 0); len(wds) != 0 {
		t.Errorf("no withdrawal row should exist, got %d", len(wds))
	}
}

// TestStripeUnlinkRouteRejectsAPIKey: unlink is account management — it must
// require an interactive Privy session, not be reachable with a (leakable)
// inference API key.
func TestStripeUnlinkRouteRejectsAPIKey(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-unlink-key", "alice@example.com", false)

	rawKey, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
	if err != nil {
		t.Fatalf("create api key: %v", err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req.Header.Set("Authorization", "Bearer "+rawKey)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("got %d, want 403 (API keys must not unlink payout accounts): %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID == "" {
		t.Error("account must still be linked")
	}
}
