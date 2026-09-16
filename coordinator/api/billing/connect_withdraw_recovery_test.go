package billing

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
