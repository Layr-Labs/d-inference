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
	"sync/atomic"
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

// accountServingStripe returns a fake Stripe that answers GET
// /v1/accounts/{id} with a healthy account under the given service agreement
// (echoing the requested ID), GET /v1/payouts/{id} with a live-"paid" payout
// (the sweep matcher verifies payout status before claiming rows), and
// 200-empty for everything else.
func accountServingStripe(agreement string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/accounts/") {
			id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
			_, _ = w.Write([]byte(healthyAccountJSON(id, "US", agreement, false)))
			return
		}
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/payouts/") {
			id := strings.TrimPrefix(r.URL.Path, "/v1/payouts/")
			_, _ = w.Write([]byte(`{"id":"` + id + `","status":"paid","amount":450,"method":"standard"}`))
			return
		}
	}))
}

// TestConnectWebhookPayoutBounceAfterPaidReopens: Stripe documents
// payout.failed arriving AFTER payout.paid for the same payout (the bank
// bounces it days later — funds return to the connected balance). Because the
// row is looked up by the event's payout ID, the failure is provably about
// the row's own payout: the row must reopen to "transferred" (so the sweep
// retries and the 48h stuck detector can see it), the instant fee must be
// refunded once, and the dead payout ID detached.
func TestConnectWebhookPayoutBounceAfterPaidReopens(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-paid-bounce", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-paid-bounce", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "paid", TransferID: "tr_pb", PayoutID: "po_pb",
	})
	balBefore := st.GetBalance(user.AccountID)

	payload := payoutEventPayload("po_pb", user.StripeAccountID, "failed", false, time.Now().Unix())
	if w := deliverConnectWebhook(t, srv, payload); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	wd, _ := st.GetStripeWithdrawal("wd-paid-bounce")
	if wd.Status != "transferred" {
		t.Errorf("status = %q, want transferred (bounced payout reopens for the sweep)", wd.Status)
	}
	if !wd.FeeRefunded {
		t.Error("instant fee should be refunded — the user is getting the standard rail")
	}
	if wd.PayoutID != "" {
		t.Errorf("dead payout ID should be detached, got %q", wd.PayoutID)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore+500_000 {
		t.Errorf("balance = %d, want %d (fee refunded exactly once)", bal, balBefore+500_000)
	}

	// Redelivery: the payout ID no longer matches a row and the payout is
	// not automatic — no-op, no double credit.
	if w := deliverConnectWebhook(t, srv, payload); w.Code != http.StatusOK {
		t.Fatalf("redelivery got %d", w.Code)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore+500_000 {
		t.Errorf("redelivery double-credited: balance = %d", bal)
	}
	wd, _ = st.GetStripeWithdrawal("wd-paid-bounce")
	if wd.Status != "transferred" {
		t.Errorf("redelivery changed status to %q", wd.Status)
	}
}

// TestConnectWebhookStalePayoutFailureLeavesPaidRow: a payout.failed whose
// payout ID matches no row (e.g. an older payout that was already detached,
// or a payout that isn't ours) must not touch rows that were completed by a
// sweep — unmatched non-automatic payouts are ignored.
func TestConnectWebhookStalePayoutFailureLeavesPaidRow(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-stale-fail", "alice@example.com", false)

	// Paid via sweep: no payout ID of its own.
	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-stale-fail", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "paid", TransferID: "tr_sf",
	})
	balBefore := st.GetBalance(user.AccountID)

	w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_stale_detached", user.StripeAccountID, "failed", false, time.Now().Unix()))
	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	wd, _ := st.GetStripeWithdrawal("wd-stale-fail")
	if wd.Status != "paid" {
		t.Errorf("status = %q, want paid (stale failures never touch completed rows)", wd.Status)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore {
		t.Errorf("balance moved: %d -> %d", balBefore, bal)
	}
}

// TestConnectWebhookPayoutBounceOnPaidRefundedRowUntouched: paid AND refunded
// is the ambiguous legacy double-state — a matched payout failure must not
// reopen or re-credit it, only surface it for manual review.
func TestConnectWebhookPayoutBounceOnPaidRefundedRowUntouched(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-paid-refunded", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-paid-refunded", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "paid", TransferID: "tr_pr", PayoutID: "po_pr",
		Refunded: true,
	})
	balBefore := st.GetBalance(user.AccountID)

	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_pr", user.StripeAccountID, "failed", false, time.Now().Unix())); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	wd, _ := st.GetStripeWithdrawal("wd-paid-refunded")
	if wd.Status != "paid" || !wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want paid/true (untouched)", wd.Status, wd.Refunded)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore {
		t.Errorf("balance moved on paid+refunded row: %d -> %d", balBefore, bal)
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
	fakeStripe := accountServingStripe("full")
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

// TestConnectWebhookSweepRecipientCutoffSkipsUnsettledRows: transfers to
// recipient-agreement accounts take +24h to become available, so a sweep
// cannot contain a transfer younger than that — claiming it early would hide
// the row from the 48h stuck detector if the next sweep failed. Rows past
// the availability delay are claimed; younger rows wait for the next sweep.
func TestConnectWebhookSweepRecipientCutoffSkipsUnsettledRows(t *testing.T) {
	fakeStripe := accountServingStripe("recipient")
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-sweep-recipient", "alice@example.com", false)

	sweepTime := time.Now()
	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-rec-settled", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_rs",
		CreatedAt: sweepTime.Add(-30 * time.Hour), // past the +24h availability delay
	})
	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-rec-unsettled", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_ru",
		CreatedAt: sweepTime.Add(-2 * time.Hour), // still inside the delay window
	})

	w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_sweep_rec", user.StripeAccountID, "paid", true, sweepTime.Unix()))
	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}

	settled, _ := st.GetStripeWithdrawal("wd-rec-settled")
	if settled.Status != "paid" {
		t.Errorf("settled row = %q, want paid", settled.Status)
	}
	unsettled, _ := st.GetStripeWithdrawal("wd-rec-unsettled")
	if unsettled.Status != "transferred" {
		t.Errorf("unsettled row = %q, want transferred (funds could not be in this sweep)", unsettled.Status)
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
		"data":{"object":{"id":"` + transferID + `","amount":450,"amount_reversed":450,"reversed":true}}
	}`)
}

// partialTransferReversedPayload models a partial reversal: amount_reversed <
// amount, and Stripe keeps reversed=false until the transfer is fully undone.
func partialTransferReversedPayload(transferID string, amountReversed int) []byte {
	return []byte(`{
		"type":"transfer.reversed","account":"",
		"data":{"object":{"id":"` + transferID + `","amount":450,"amount_reversed":` +
		strconv.Itoa(amountReversed) + `,"reversed":false}}
	}`)
}

// TestConnectWebhookPartialTransferReversalNoAutoRefund: partial reversals
// (always ops-initiated — our code never creates them) must not auto-credit
// the ledger or terminalize the row: crediting the full net would over-pay,
// and even the partial amount may be compensating a manual ledger adjustment.
// A later FULL reversal still makes the user whole exactly once.
func TestConnectWebhookPartialTransferReversalNoAutoRefund(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-rev-partial", "alice@example.com", false)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-rev-partial", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_partial",
	})
	balBefore := st.GetBalance(user.AccountID)

	// Partial reversal: no ledger movement, row stays non-terminal.
	if w := deliverConnectWebhook(t, srv, partialTransferReversedPayload("tr_partial", 200)); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	wd, _ := st.GetStripeWithdrawal("wd-rev-partial")
	if wd.Status != "transferred" || wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want transferred/false (manual review only)", wd.Status, wd.Refunded)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore {
		t.Errorf("partial reversal moved the ledger: %d -> %d", balBefore, bal)
	}

	// The reversal is later completed: normal full-reversal semantics.
	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_partial")); w.Code != http.StatusOK {
		t.Fatalf("full reversal got %d", w.Code)
	}
	wd, _ = st.GetStripeWithdrawal("wd-rev-partial")
	if wd.Status != "failed" || !wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want failed/true", wd.Status, wd.Refunded)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore+5_000_000 {
		t.Errorf("balance = %d, want %d (refunded exactly once, on full reversal)", bal, balBefore+5_000_000)
	}
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

// TestConnectWebhookTransferReversedDedupesFeeByLedgerRef: the fee dedupe
// must hold even when the FeeRefunded FLAG was lost (persist failure after
// the fee credit landed) — the ledger reference, not the flag, is the source
// of truth.
func TestConnectWebhookTransferReversedDedupesFeeByLedgerRef(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-rev-flagless", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-rev-flagless", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "transferred", TransferID: "tr_rev_fl",
		FeeRefunded: false, // flag lost…
	})
	// …but the fee credit itself landed under its ledger reference.
	if err := st.CreditWithdrawable(user.AccountID, 500_000, store.LedgerRefund,
		"stripe_withdraw_fee:wd-rev-flagless"); err != nil {
		t.Fatal(err)
	}
	balBefore := st.GetBalance(user.AccountID)

	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_rev_fl")); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	// Only the net part credits; the fee ref already exists.
	if bal := st.GetBalance(user.AccountID); bal != balBefore+4_500_000 {
		t.Errorf("balance = %d, want %d (fee deduped by ledger ref despite lost flag)", bal, balBefore+4_500_000)
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
// ambiguous — never auto-refund, durably quarantine it for manual review.
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
	if wd.Status != "review_pending" || wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want review_pending/false", wd.Status, wd.Refunded)
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

// TestConnectWebhookTransferReversedConvergesAcrossPersistFailure proves the
// reversal path no longer has a credit-versus-row persist seam: the dedicated
// atomic store operation succeeds even when the legacy Update method is faulted.
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
	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_conv")); w.Code != http.StatusOK {
		t.Fatalf("atomic reversal got %d", w.Code)
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
	fakeStripe := accountServingStripe("full")
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

// --- Round-5: ambiguous Stripe outcomes must never auto-refund ---

// droppingStripe builds a fake Stripe that serves a healthy account on GET
// /v1/accounts/*, drops the connection (transport error, outcome unknown) for
// the first failN requests to dropPath, and delegates the rest to next.
func droppingStripe(t *testing.T, dropPath string, failN int, next http.HandlerFunc) *httptest.Server {
	t.Helper()
	var calls int32
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
			_, _ = w.Write([]byte(healthyAccountJSON(id, "US", "full", true)))
			return
		}
		if r.URL.Path == dropPath && atomic.AddInt32(&calls, 1) <= int32(failN) {
			hj, ok := w.(http.Hijacker)
			if !ok {
				t.Fatal("recorder not hijackable")
			}
			conn, _, err := hj.Hijack()
			if err != nil {
				t.Fatalf("hijack: %v", err)
			}
			_ = conn.Close() // response lost in flight — ambiguous outcome
			return
		}
		if next != nil {
			next(w, r)
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
}

// TestStripeWithdrawAmbiguousTransferParksRowWithoutRefund: when Stripe never
// answers transfers.create (idempotent request possibly accepted), refunding
// would double-pay if the sweep later delivers the accepted transfer. The row
// must park in "pending" with NO refund, surfaced by the reconciler.
func TestStripeWithdrawAmbiguousTransferParksRowWithoutRefund(t *testing.T) {
	fakeStripe := droppingStripe(t, "/v1/transfers", 99, nil)
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-ambig-tr", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	// Debited, NOT refunded — the transfer may have been accepted.
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (debit stands, no refund on ambiguity)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("want 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Status != "pending" || wds[0].Refunded {
		t.Errorf("row = status %q refunded=%v, want pending/false (parked for reconciliation)", wds[0].Status, wds[0].Refunded)
	}
	if !strings.Contains(wds[0].FailureReason, "transfer_create_unconfirmed") {
		t.Errorf("failure reason = %q, want transfer_create_unconfirmed", wds[0].FailureReason)
	}
}

// TestStripeWithdrawAmbiguousTransferRetryRecovers: a single dropped response
// followed by a successful idempotent replay completes the withdrawal
// normally — one debit, no refund, row transferred.
func TestStripeWithdrawAmbiguousTransferRetryRecovers(t *testing.T) {
	fakeStripe := droppingStripe(t, "/v1/transfers", 1, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/transfers" && r.Method == http.MethodPost {
			_, _ = w.Write([]byte(`{"id":"tr_recovered","amount":500,"destination":"acct_x","created":1}`))
			return
		}
	})
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-ambig-rec", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (exactly one debit)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 || wds[0].Status != "transferred" || wds[0].TransferID != "tr_recovered" {
		t.Errorf("row = %+v, want transferred with tr_recovered", wds[0])
	}
}

// TestStripeWithdrawAmbiguousInstantPayoutKeepsFee: when payouts.create times
// out, the payout may exist (user gets instant delivery) — the fee must NOT
// be refunded and the row must stay observable (transferred, no payout ID).
func TestStripeWithdrawAmbiguousInstantPayoutKeepsFee(t *testing.T) {
	fakeStripe := droppingStripe(t, "/v1/payouts", 99, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/transfers" && r.Method == http.MethodPost {
			_, _ = w.Write([]byte(`{"id":"tr_ambig_po","amount":450,"destination":"acct_x","created":1}`))
			return
		}
	})
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-ambig-po", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusAccepted {
		t.Fatalf("got %d, want 202: %s", w.Code, w.Body.String())
	}
	// Gross debited, fee NOT refunded (payout may have delivered).
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (fee kept until outcome is known)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("want 1 withdrawal row, got %d", len(wds))
	}
	wd := wds[0]
	if wd.Status != "transferred" || wd.PayoutID != "" || wd.FeeRefunded {
		t.Errorf("row = status %q payout %q feeRefunded=%v, want transferred/empty/false", wd.Status, wd.PayoutID, wd.FeeRefunded)
	}
	if !strings.Contains(wd.FailureReason, "instant_payout_unconfirmed") {
		t.Errorf("failure reason = %q, want instant_payout_unconfirmed", wd.FailureReason)
	}
}

// TestConnectWebhookPayoutPaidOnRefundedRowStaysFailed: if transfer.reversed
// already refunded the ledger and the row still carries its instant payout
// ID, a late/redelivered payout.paid must not overwrite the refunded row to
// "paid" — that would hide a possible double payment.
func TestConnectWebhookPayoutPaidOnRefundedRowStaysFailed(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-paid-on-ref", "alice@example.com", true)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-paid-on-ref", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "failed", TransferID: "tr_por", PayoutID: "po_por",
		Refunded: true, FailureReason: "transfer_reversed",
	})
	balBefore := st.GetBalance(user.AccountID)

	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_por", user.StripeAccountID, "paid", false, time.Now().Unix())); w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	wd, _ := st.GetStripeWithdrawal("wd-paid-on-ref")
	if wd.Status != "failed" || !wd.Refunded {
		t.Errorf("row = status %q refunded=%v, want failed/true (manual review, never paid)", wd.Status, wd.Refunded)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore {
		t.Errorf("balance moved: %d -> %d", balBefore, bal)
	}
}

// TestStripeWithdraw500TransferParksRowWithoutRefund: Stripe documents 5xx
// on POST mutations as indeterminate and possibly side-effecting — a 500
// from transfers.create must take the unconfirmed path (idempotent replays,
// then park without refund), never the definitive refund path.
func TestStripeWithdraw500TransferParksRowWithoutRefund(t *testing.T) {
	var transferCalls int32
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
			_, _ = w.Write([]byte(healthyAccountJSON(id, "US", "full", false)))
			return
		}
		if r.URL.Path == "/v1/transfers" {
			atomic.AddInt32(&transferCalls, 1)
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":{"message":"An unknown error occurred","type":"api_error"}}`))
			return
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-500-tr", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	if n := atomic.LoadInt32(&transferCalls); n != 3 {
		t.Errorf("transfer attempts = %d, want 3 (idempotent replays before parking)", n)
	}
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (500 is indeterminate — no refund)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 || wds[0].Status != "pending" || wds[0].Refunded {
		t.Errorf("row = %+v, want pending/unrefunded (parked for reconciliation)", wds[0])
	}
}

// TestConnectWebhookSweepBounceReopensClaimedRows: when an automatic sweep's
// payout.failed arrives after its payout.paid (bank bounce), the rows that
// sweep claimed must reopen to "transferred" — otherwise money parked back
// in the connected balance hides behind terminal "paid" rows. Rows claimed
// by OTHER sweeps stay paid.
func TestConnectWebhookSweepBounceReopensClaimedRows(t *testing.T) {
	fakeStripe := accountServingStripe("full")
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-sweep-bounce", "alice@example.com", false)

	sweepTime := time.Now()
	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-sb-1", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_sb1",
		CreatedAt: sweepTime.Add(-3 * time.Hour),
	})
	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-sb-2", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 3_000_000, NetMicroUSD: 3_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_sb2",
		CreatedAt: sweepTime.Add(-4 * time.Hour),
	})
	// Claimed by an OLDER sweep — must stay paid.
	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-sb-old", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 2_000_000, NetMicroUSD: 2_000_000,
		Method: "standard", Status: "paid", TransferID: "tr_sb0", SweepPayoutID: "po_sweep_old",
		CreatedAt: sweepTime.Add(-48 * time.Hour),
	})
	balBefore := st.GetBalance(user.AccountID)

	// The sweep pays: both transferred rows are claimed and stamped.
	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_sweep_b", user.StripeAccountID, "paid", true, sweepTime.Unix())); w.Code != http.StatusOK {
		t.Fatalf("sweep paid got %d: %s", w.Code, w.Body.String())
	}
	for _, id := range []string{"wd-sb-1", "wd-sb-2"} {
		wd, _ := st.GetStripeWithdrawal(id)
		if wd.Status != "paid" || wd.SweepPayoutID != "po_sweep_b" {
			t.Fatalf("%s = status %q sweep %q, want paid/po_sweep_b", id, wd.Status, wd.SweepPayoutID)
		}
	}

	// The same sweep bounces: its rows reopen; the older sweep's row stays.
	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_sweep_b", user.StripeAccountID, "failed", true, sweepTime.Unix())); w.Code != http.StatusOK {
		t.Fatalf("sweep failed got %d: %s", w.Code, w.Body.String())
	}
	for _, id := range []string{"wd-sb-1", "wd-sb-2"} {
		wd, _ := st.GetStripeWithdrawal(id)
		if wd.Status != "transferred" || wd.SweepPayoutID != "" {
			t.Errorf("%s = status %q sweep %q, want transferred/empty (reopened)", id, wd.Status, wd.SweepPayoutID)
		}
		if !strings.Contains(wd.FailureReason, "sweep_payout_failed") {
			t.Errorf("%s failure reason = %q", id, wd.FailureReason)
		}
	}
	old, _ := st.GetStripeWithdrawal("wd-sb-old")
	if old.Status != "paid" || old.SweepPayoutID != "po_sweep_old" {
		t.Errorf("older sweep's row = status %q sweep %q, want paid/po_sweep_old (untouched)", old.Status, old.SweepPayoutID)
	}
	if bal := st.GetBalance(user.AccountID); bal != balBefore {
		t.Errorf("sweep bounce moved the ledger: %d -> %d", balBefore, bal)
	}

	// A redelivered payout.paid from the BOUNCED sweep must not re-claim the
	// reopened rows: their reopen bumped UpdatedAt past the old sweep's
	// creation time, so only a sweep cut AFTER the reopen (one that can
	// actually contain the re-parked funds) may complete them.
	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_sweep_b", user.StripeAccountID, "paid", true, sweepTime.Unix())); w.Code != http.StatusOK {
		t.Fatalf("stale sweep paid redelivery got %d: %s", w.Code, w.Body.String())
	}
	for _, id := range []string{"wd-sb-1", "wd-sb-2"} {
		wd, _ := st.GetStripeWithdrawal(id)
		if wd.Status != "transferred" {
			t.Errorf("%s re-claimed by the bounced sweep's stale paid event: status %q", id, wd.Status)
		}
	}

	// A NEW sweep cut after the reopen delivers and completes them.
	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_sweep_b2", user.StripeAccountID, "paid", true, time.Now().Add(time.Hour).Unix())); w.Code != http.StatusOK {
		t.Fatalf("retry sweep paid got %d: %s", w.Code, w.Body.String())
	}
	for _, id := range []string{"wd-sb-1", "wd-sb-2"} {
		wd, _ := st.GetStripeWithdrawal(id)
		if wd.Status != "paid" || wd.SweepPayoutID != "po_sweep_b2" {
			t.Errorf("%s = status %q sweep %q, want paid/po_sweep_b2 (claimed by the retry sweep)", id, wd.Status, wd.SweepPayoutID)
		}
	}
}

// TestConnectWebhookRefundedRowFlipRedelivers: the failed-status flip on an
// already-refunded row is what keeps it out of sweep reconciliation — a
// transient persist failure must 500 (so Stripe redelivers) instead of
// acking and leaving the refunded row claimable.
func TestConnectWebhookRefundedRowFlipRedelivers(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, flaky := newFlakyPayoutServer(t, fakeStripe)
	user := readyUser(t, flaky.MemoryStore, "acct-ref-flip", "alice@example.com", false)

	// Legacy shape: ledger refunded but row never flipped to failed.
	mkWithdrawal(t, flaky.MemoryStore, store.StripeWithdrawal{
		ID: "wd-ref-flip", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_rf_flip",
		Refunded: true,
	})

	flaky.failUpdates = true
	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_rf_flip")); w.Code != http.StatusInternalServerError {
		t.Fatalf("got %d, want 500 (persist failed — Stripe must redeliver)", w.Code)
	}

	flaky.failUpdates = false
	if w := deliverConnectWebhook(t, srv, transferReversedPayload("tr_rf_flip")); w.Code != http.StatusOK {
		t.Fatalf("redelivery got %d", w.Code)
	}
	wd, _ := flaky.GetStripeWithdrawal("wd-ref-flip")
	if wd.Status != "failed" {
		t.Errorf("status = %q, want failed (terminal, out of sweep reconciliation)", wd.Status)
	}
}

// TestConnectWebhookStaleSweepPaidForFailedPayoutNoClaim: webhook delivery
// order isn't guaranteed — a payout.failed can be DELIVERED before the same
// sweep's payout.paid. The paid handler verifies the payout's live status
// with Stripe before claiming rows; a payout that already failed claims
// nothing (the funds are back in the balance and the next sweep delivers).
func TestConnectWebhookStaleSweepPaidForFailedPayoutNoClaim(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/accounts/") {
			id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
			_, _ = w.Write([]byte(healthyAccountJSON(id, "US", "full", false)))
			return
		}
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/payouts/") {
			id := strings.TrimPrefix(r.URL.Path, "/v1/payouts/")
			_, _ = w.Write([]byte(`{"id":"` + id + `","status":"failed","amount":450,"method":"standard","failure_code":"could_not_process"}`))
			return
		}
	}))
	defer fakeStripe.Close()
	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-stale-sweep", "alice@example.com", false)

	mkWithdrawal(t, st, store.StripeWithdrawal{
		ID: "wd-stale-sweep", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_ss",
		CreatedAt: time.Now().Add(-3 * time.Hour),
	})

	// The failure was delivered first: no rows were stamped, so it was a
	// no-op. The stale paid event arrives afterwards.
	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_stale_sweep", user.StripeAccountID, "failed", true, time.Now().Unix())); w.Code != http.StatusOK {
		t.Fatalf("failed delivery got %d", w.Code)
	}
	if w := deliverConnectWebhook(t, srv,
		payoutEventPayload("po_stale_sweep", user.StripeAccountID, "paid", true, time.Now().Unix())); w.Code != http.StatusOK {
		t.Fatalf("stale paid delivery got %d", w.Code)
	}

	wd, _ := st.GetStripeWithdrawal("wd-stale-sweep")
	if wd.Status != "transferred" {
		t.Errorf("status = %q, want transferred (live payout status is failed — nothing claimed)", wd.Status)
	}
}
