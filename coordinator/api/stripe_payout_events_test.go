package api

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

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
