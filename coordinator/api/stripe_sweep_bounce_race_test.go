package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Return the old sweep's snapshot after a concurrent bounce delivery has
// reopened the row and a newer sweep has completed it.
type replacedSweepStore struct {
	*store.MemoryStore
	t *testing.T
}

func (s *replacedSweepStore) ListStripeWithdrawalsBySweepPayoutID(id string) ([]store.StripeWithdrawal, error) {
	rows, err := s.MemoryStore.ListStripeWithdrawalsBySweepPayoutID(id)
	for _, row := range rows {
		row.Status, row.SweepPayoutID = "transferred", ""
		if err := s.MemoryStore.UpdateStripeWithdrawal(&row); err != nil {
			s.t.Fatal(err)
		}
		if applied, err := s.MemoryStore.MarkStripeWithdrawalPaid(row.ID, "", "po_new"); err != nil || !applied {
			s.t.Fatalf("new sweep completion: applied=%v err=%v", applied, err)
		}
	}
	return rows, err
}

func TestConnectWebhookOldSweepBouncePreservesNewSweepCompletion(t *testing.T) {
	fakeStripe := accountServingStripe("full")
	defer fakeStripe.Close()
	srv, mem := stripePayoutsTestServer(t, false, fakeStripe)
	st := &replacedSweepStore{MemoryStore: mem, t: t}
	srv.SetBilling(billing.NewService(st, payments.NewLedger(st), srv.logger, billing.Config{
		StripeSecretKey: "sk_test_fake", StripeConnectWebhookSecret: "whsec_test",
		StripeConnectReturnURL: "https://app.test/billing", StripeConnectRefreshURL: "https://app.test/billing",
		StripeConnectPlatformCountry: "US",
	}))
	user := readyUser(t, mem, "acct-sweep-race", "alice@example.com", false)
	mkWithdrawal(t, mem, store.StripeWithdrawal{
		ID: "wd-sweep-race", AccountID: user.AccountID, StripeAccountID: user.StripeAccountID,
		AmountMicroUSD: 5_000_000, NetMicroUSD: 5_000_000,
		Method: "standard", Status: "paid", TransferID: "tr_sweep_race", SweepPayoutID: "po_old",
	})
	before := mem.GetBalance(user.AccountID)
	response := deliverConnectWebhook(t, srv, payoutEventPayload("po_old", user.StripeAccountID, "failed", true, time.Now().Unix()))
	if response.Code != http.StatusOK {
		t.Fatalf("webhook returned %d: %s", response.Code, response.Body.String())
	}
	wd, err := mem.GetStripeWithdrawal("wd-sweep-race")
	if err != nil {
		t.Fatal(err)
	}
	if wd.Status != "paid" || wd.SweepPayoutID != "po_new" || mem.GetBalance(user.AccountID) != before {
		t.Fatalf("new sweep completion overwritten: status=%s sweep=%q balance=%d want=%d", wd.Status, wd.SweepPayoutID, mem.GetBalance(user.AccountID), before)
	}
}
