package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// --- Reconciler ---

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
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
		ID: "wd-stuck-1", AccountID: user.AccountID, StripeAccountID: "acct_stuck_1",
		TransferID: "tr_stuck_1", AmountMicroUSD: 10_570_000, NetMicroUSD: 10_570_000,
		Method: "standard", Status: "transferred", CreatedAt: time.Now().Add(-72 * time.Hour),
	})
	// A fresh transferred row must NOT trigger reconciliation.
	_ = st.CreateStripeWithdrawal(&store.StripeWithdrawal{
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
