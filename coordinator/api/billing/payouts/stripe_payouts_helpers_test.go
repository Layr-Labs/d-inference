package payouts

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// seedWithdrawal inserts wd through the production path: it credits the gross
// amount as withdrawable, then CreateStripeWithdrawalWithDebit debits it and
// inserts the row, leaving the account's balances where they were.
func seedWithdrawal(t *testing.T, st *memory.MemoryStore, wd store.StripeWithdrawal) {
	t.Helper()
	if err := st.CreditWithdrawable(wd.AccountID, wd.AmountMicroUSD, store.LedgerPayout, "seed:"+wd.ID); err != nil {
		t.Fatalf("seed withdrawable for %s: %v", wd.ID, err)
	}
	if err := st.CreateStripeWithdrawalWithDebit(&wd, store.LedgerStripePayout, "stripe_withdraw:"+wd.ID); err != nil {
		t.Fatalf("create withdrawal %s: %v", wd.ID, err)
	}
}
