package billing_test

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	srv.Handler().ServeHTTP(w, req)

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
	if err := st.CreateStripeWithdrawalWithDebit(&store.StripeWithdrawal{
		ID:              withdrawalID,
		AccountID:       user.AccountID,
		StripeAccountID: user.StripeAccountID,
		PayoutID:        "po_failtest",
		AmountMicroUSD:  5_000_000,
		FeeMicroUSD:     0,
		NetMicroUSD:     5_000_000,
		Method:          "standard",
		Status:          "transferred",
	}, store.LedgerStripePayout, "stripe_withdraw:"+withdrawalID); err != nil {
		t.Fatalf("create withdrawal: %v", err)
	}

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
	srv.Handler().ServeHTTP(w, req)

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
	if err := st.CreateStripeWithdrawalWithDebit(&store.StripeWithdrawal{
		ID: withdrawalID, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		PayoutID: "po_idem", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred",
	}, store.LedgerStripePayout, "stripe_withdraw:"+withdrawalID); err != nil {
		t.Fatalf("create withdrawal: %v", err)
	}

	payload := []byte(`{
		"type":"payout.failed","account":"` + user.StripeAccountID + `",
		"data":{"object":{"id":"po_idem","status":"failed","amount":500,"method":"standard","failure_code":"x","failure_message":"y"}}
	}`)

	for i := range 3 {
		req := signedConnectRequest(t, payload, "whsec_test")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
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
	seedWithdrawal(t, st, store.StripeWithdrawal{
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
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("got %d", w.Code)
	}

	wd, _ := st.GetStripeWithdrawal("wd-legacy-1")
	if wd.Status != "failed" {
		t.Errorf("status = %q, want failed (terminal for already-refunded rows)", wd.Status)
	}
}

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
		seedWithdrawal(t, st, store.StripeWithdrawal{
			ID: id, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
			AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
			Method: "standard", Status: status, CreatedAt: createdAt,
		})
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
	srv.Handler().ServeHTTP(w, req)
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
	seedWithdrawal(t, st, store.StripeWithdrawal{
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
	srv.Handler().ServeHTTP(w, req)
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
	if err := st.CreateStripeWithdrawalWithDebit(&store.StripeWithdrawal{
		ID: withdrawalID, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		PayoutID: "po_paid", AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred",
	}, store.LedgerStripePayout, "stripe_withdraw:"+withdrawalID); err != nil {
		t.Fatalf("create withdrawal: %v", err)
	}

	payload := []byte(`{
		"type":"payout.paid","account":"` + user.StripeAccountID + `",
		"data":{"object":{"id":"po_paid","status":"paid","amount":500,"method":"standard"}}
	}`)
	for i := range 3 {
		req := signedConnectRequest(t, payload, "whsec_test")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
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
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 on bad signature", w.Code)
	}
}
