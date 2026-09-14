package billing

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

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
		if err := st.CreateStripeWithdrawal(&store.StripeWithdrawal{
			ID: id, AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
			AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
			Method: "standard", Status: status, CreatedAt: createdAt,
		}); err != nil {
			t.Fatalf("create withdrawal %s: %v", id, err)
		}
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
	srv.StripeConnectWebhook(w, req)
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
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
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
	srv.StripeConnectWebhook(w, req)
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
