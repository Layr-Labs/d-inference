package conformance

import (
	"sort"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// serviceHoldProbeModel only labels the probe's reservation metrics.
const serviceHoldProbeModel = "conformance-hold-probe"

// OutstandingServiceHold measures, in micro-USD, the service hold that account
// has reserved and not yet released. The reservation controller keeps that
// per-account sum private, so the measurement uses the controller's own
// admission rule: ReserveInitial admits a service reservation only while the
// balance in st, the store the controller is bound to, minus the outstanding
// sum covers it. The largest admitted amount is therefore the unheld balance.
// Every admitted probe is released before the next one; service holds exist
// only in memory, so measuring leaves the ledger untouched.
//
// The test fails unless service reservations are enabled, account is a service
// account and its balance is positive. A hold above the balance reads as the
// balance. A reading is exact only while the account's balance and holds stay
// unchanged during the call, and a probe briefly holds the amount it tests: do
// not measure while a request for the account is being admitted, and poll
// while a settlement may still be landing.
func OutstandingServiceHold(t *testing.T, controller *reservations.Controller, st store.Store, account string) int64 {
	t.Helper()
	balance := st.GetBalance(account)
	if balance <= 0 {
		t.Fatalf("service hold probe needs a positive balance, got %d", balance)
	}
	admits := func(amount int64) bool {
		serviceMode, err := controller.ReserveInitial(account, serviceHoldProbeModel, amount)
		if !serviceMode {
			if err == nil {
				// Ledger mode debited the probe; refund it before failing.
				controller.ReleaseInitial(account, serviceHoldProbeModel, amount, false)
			}
			t.Fatalf("service hold probe for %q did not use the in-memory hold (err=%v)", account, err)
		}
		if err != nil {
			return false
		}
		controller.ReleaseInitial(account, serviceHoldProbeModel, amount, true)
		return true
	}
	// Amounts 1..unheld are admitted and every larger amount is refused. Index i
	// probes amount i+1, so the first refused index is the unheld balance.
	unheld := int64(sort.Search(int(balance), func(i int) bool { return !admits(int64(i) + 1) }))
	return balance - unheld
}
