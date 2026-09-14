package billing

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

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
