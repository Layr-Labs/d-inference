package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// paidDuringReversalStore makes payout.paid win after reversal reads the row.
// Returning that old copy models the two independent webhook requests without
// relying on scheduler timing.
type paidDuringReversalStore struct {
	*store.MemoryStore
	t *testing.T
}

func (s *paidDuringReversalStore) GetStripeWithdrawalByTransferID(id string) (*store.StripeWithdrawal, error) {
	wd, err := s.MemoryStore.GetStripeWithdrawalByTransferID(id)
	if err == nil {
		applied, markErr := s.MarkStripeWithdrawalPaid(wd.ID, wd.PayoutID, "")
		if markErr != nil || !applied {
			s.t.Fatalf("concurrent payout completion: applied=%v err=%v", applied, markErr)
		}
	}
	return wd, err
}

func TestConnectWebhookReversalDoesNotRefundConcurrentlyPaidWithdrawal(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer fakeStripe.Close()
	srv, mem := stripePayoutsTestServer(t, false, fakeStripe)
	st := &paidDuringReversalStore{MemoryStore: mem, t: t}
	srv.SetBilling(billing.NewService(st, payments.NewLedger(st), srv.logger, billing.Config{
		StripeSecretKey: "sk_test_fake", StripeConnectWebhookSecret: "whsec_test",
		StripeConnectReturnURL: "https://app.test/billing", StripeConnectRefreshURL: "https://app.test/billing",
		StripeConnectPlatformCountry: "US",
	}))
	user := readyUser(t, mem, "acct-reversal-race", "alice@example.com", false)
	mkWithdrawal(t, mem, store.StripeWithdrawal{
		ID: "wd-reversal-race", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "transferred", TransferID: "tr_reversal_race", PayoutID: "po_reversal_race",
	})
	before := mem.GetBalance(user.AccountID)
	if response := deliverConnectWebhook(t, srv, transferReversedPayload("tr_reversal_race")); response.Code != http.StatusOK {
		t.Fatalf("webhook returned %d: %s", response.Code, response.Body.String())
	}
	wd, err := mem.GetStripeWithdrawal("wd-reversal-race")
	if err != nil {
		t.Fatal(err)
	}
	if wd.Status != "paid" || wd.Refunded || mem.GetBalance(user.AccountID) != before {
		t.Fatalf("concurrently paid withdrawal must stay unchanged for manual review: status=%s refunded=%v balance=%d want=%d", wd.Status, wd.Refunded, mem.GetBalance(user.AccountID), before)
	}
}
