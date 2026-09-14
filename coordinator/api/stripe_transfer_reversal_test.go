package api

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
)

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
