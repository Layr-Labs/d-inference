package store

import (
	"errors"
	"testing"
	"time"
)

func TestStripeWithdrawalStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testStripeWithdrawalStoreContract(t, st)
		})
	}
}

func testStripeWithdrawalStoreContract(t *testing.T, st Store) {
	t.Helper()

	accountID := uniqueID("withdrawal-account")
	stripeAccountID := uniqueID("stripe-account")
	if err := st.CreateUser(&User{
		AccountID: accountID, PrivyUserID: uniqueID("withdrawal-privy"),
	}); err != nil {
		t.Fatalf("create withdrawal user: %v", err)
	}
	if err := st.SetUserStripeAccount(accountID, stripeAccountID, "ready", "US", "bank", "6789", false); err != nil {
		t.Fatalf("set withdrawal Stripe account: %v", err)
	}

	base := time.Date(2026, time.August, 22, 12, 0, 0, 0, time.UTC)
	withdrawalID := uniqueID("withdrawal")
	transferID := uniqueID("tr")
	payoutID := uniqueID("po")
	withdrawal := &StripeWithdrawal{
		ID: withdrawalID, AccountID: accountID, StripeAccountID: stripeAccountID,
		AmountMicroUSD: 5_000_000, FeeMicroUSD: 500_000, NetMicroUSD: 4_500_000,
		Method: "instant", Status: "pending", CreatedAt: base,
	}
	if err := st.CreateStripeWithdrawal(withdrawal); err != nil {
		t.Fatalf("create withdrawal: %v", err)
	}
	if err := st.CreateStripeWithdrawal(withdrawal); err == nil {
		t.Fatal("duplicate withdrawal ID succeeded")
	}
	got, err := st.GetStripeWithdrawal(withdrawalID)
	if err != nil {
		t.Fatalf("get withdrawal: %v", err)
	}
	if got.AmountMicroUSD != withdrawal.AmountMicroUSD ||
		got.FeeMicroUSD != withdrawal.FeeMicroUSD ||
		got.NetMicroUSD != withdrawal.NetMicroUSD ||
		got.Method != withdrawal.Method ||
		got.Status != "pending" ||
		got.FeeRefunded {
		t.Fatalf("withdrawal round-trip mismatch: %+v", got)
	}

	got.TransferID = transferID
	got.PayoutID = payoutID
	got.Status = "transferred"
	got.FailureReason = "temporary"
	got.Refunded = true
	got.FeeRefunded = true
	if err := st.UpdateStripeWithdrawal(got); err != nil {
		t.Fatalf("update withdrawal: %v", err)
	}
	byTransfer, err := st.GetStripeWithdrawalByTransferID(transferID)
	if err != nil || byTransfer.ID != withdrawalID {
		t.Fatalf("get by transfer = %+v err=%v", byTransfer, err)
	}
	byPayout, err := st.GetStripeWithdrawalByPayoutID(payoutID)
	if err != nil ||
		byPayout.ID != withdrawalID ||
		!byPayout.Refunded ||
		!byPayout.FeeRefunded ||
		byPayout.FailureReason != "temporary" {
		t.Fatalf("get by payout = %+v err=%v", byPayout, err)
	}
	byPayout.PayoutID = ""
	if err := st.UpdateStripeWithdrawal(byPayout); err != nil {
		t.Fatalf("detach payout: %v", err)
	}
	if _, err := st.GetStripeWithdrawalByPayoutID(payoutID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("detached payout lookup err = %v, want ErrNotFound", err)
	}
	if _, err := st.GetStripeWithdrawalByPayoutID(uniqueID("missing-payout")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing payout lookup err = %v, want ErrNotFound", err)
	}
	if _, err := st.GetStripeWithdrawalByTransferID(uniqueID("missing-transfer")); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing transfer lookup err = %v, want ErrNotFound", err)
	}

	list, err := st.ListStripeWithdrawals(accountID, 10)
	if err != nil || len(list) != 1 || list[0].ID != withdrawalID {
		t.Fatalf("list withdrawals = %+v err=%v", list, err)
	}
	statusRows, err := st.ListStripeWithdrawalsByStatus("transferred", base.Add(time.Hour), 10)
	if err != nil || !containsWithdrawal(statusRows, withdrawalID) {
		t.Fatalf("status withdrawals = %+v err=%v", statusRows, err)
	}
	accountRows, err := st.ListStripeWithdrawalsForStripeAccount(stripeAccountID, "transferred")
	if err != nil || !containsWithdrawal(accountRows, withdrawalID) {
		t.Fatalf("Stripe-account withdrawals = %+v err=%v", accountRows, err)
	}

	reference := "stripe_withdraw_fee:" + withdrawalID
	applied, err := st.CreditWithdrawableOnce(accountID, 500_000, LedgerRefund, reference)
	if err != nil || !applied {
		t.Fatalf("first idempotent credit: applied=%v err=%v", applied, err)
	}
	applied, err = st.CreditWithdrawableOnce(accountID, 500_000, LedgerRefund, reference)
	if err != nil || applied {
		t.Fatalf("duplicate idempotent credit: applied=%v err=%v", applied, err)
	}
	if balance := st.GetBalance(accountID); balance != 500_000 {
		t.Fatalf("idempotent-credit balance = %d, want 500000", balance)
	}

	debitAccountID := uniqueID("withdrawal-debit-account")
	if err := st.CreateUser(&User{
		AccountID: debitAccountID, PrivyUserID: uniqueID("withdrawal-debit-privy"),
	}); err != nil {
		t.Fatalf("create debit user: %v", err)
	}
	if err := st.CreditWithdrawable(debitAccountID, 10_000_000, LedgerPayout, "earnings"); err != nil {
		t.Fatalf("seed withdrawable: %v", err)
	}
	atomicID := uniqueID("atomic-withdrawal")
	atomicWithdrawal := &StripeWithdrawal{
		ID: atomicID, AccountID: debitAccountID, StripeAccountID: stripeAccountID,
		AmountMicroUSD: 4_000_000, NetMicroUSD: 4_000_000,
		Method: "standard", Status: "pending", CreatedAt: base.Add(time.Minute),
	}
	if err := st.CreateStripeWithdrawalWithDebit(atomicWithdrawal, LedgerStripePayout, "stripe_withdraw:"+atomicID); err != nil {
		t.Fatalf("atomic debit and create: %v", err)
	}
	if balance, withdrawable := st.GetBalanceWithWithdrawable(debitAccountID); balance != 6_000_000 || withdrawable != 6_000_000 {
		t.Fatalf("balance/withdrawable after debit = %d/%d, want 6000000/6000000", balance, withdrawable)
	}
	insufficientID := uniqueID("insufficient-withdrawal")
	err = st.CreateStripeWithdrawalWithDebit(&StripeWithdrawal{
		ID: insufficientID, AccountID: debitAccountID, StripeAccountID: stripeAccountID,
		AmountMicroUSD: 60_000_000, NetMicroUSD: 60_000_000,
		Method: "standard", Status: "pending",
	}, LedgerStripePayout, "stripe_withdraw:"+insufficientID)
	if !errors.Is(err, ErrInsufficientBalance) {
		t.Fatalf("insufficient debit err = %v, want ErrInsufficientBalance", err)
	}
	failedWithdrawal, lookupErr := st.GetStripeWithdrawal(insufficientID)
	if lookupErr == nil || failedWithdrawal != nil {
		t.Fatalf("failed debit withdrawal = %+v err=%v, want no row", failedWithdrawal, lookupErr)
	}
	if err := st.CreateStripeWithdrawalWithDebit(&StripeWithdrawal{
		ID: atomicID, AccountID: debitAccountID, StripeAccountID: stripeAccountID,
		AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
		Method: "standard", Status: "pending",
	}, LedgerStripePayout, "stripe_withdraw:"+uniqueID("duplicate-reference")); err == nil {
		t.Fatal("duplicate atomic withdrawal ID succeeded")
	}
	if balance := st.GetBalance(debitAccountID); balance != 6_000_000 {
		t.Fatalf("failed atomic attempts changed balance: %d", balance)
	}

	createGuarded := func(status, payout string, refunded bool) string {
		t.Helper()
		id := uniqueID("guarded-withdrawal")
		if err := st.CreateStripeWithdrawal(&StripeWithdrawal{
			ID: id, AccountID: accountID, StripeAccountID: stripeAccountID,
			AmountMicroUSD: 1_000_000, NetMicroUSD: 1_000_000,
			Method: "instant", Status: status, PayoutID: payout, Refunded: refunded,
			CreatedAt: base.Add(2 * time.Minute),
		}); err != nil {
			t.Fatalf("create guarded withdrawal: %v", err)
		}
		return id
	}

	sweepID := uniqueID("sweep-payout")
	payableID := createGuarded("transferred", "", false)
	if applied, err := st.MarkStripeWithdrawalPaid(payableID, "", sweepID); err != nil || !applied {
		t.Fatalf("mark payable row: applied=%v err=%v", applied, err)
	}
	paid, err := st.GetStripeWithdrawal(payableID)
	if err != nil || paid.Status != "paid" || paid.SweepPayoutID != sweepID {
		t.Fatalf("paid row = %+v err=%v", paid, err)
	}
	if rows, err := st.ListStripeWithdrawalsBySweepPayoutID(sweepID); err != nil ||
		len(rows) != 1 ||
		rows[0].ID != payableID {
		t.Fatalf("sweep rows = %+v err=%v", rows, err)
	}
	refundedID := createGuarded("transferred", "", true)
	if applied, err := st.MarkStripeWithdrawalPaid(refundedID, "", ""); err != nil || applied {
		t.Fatalf("mark refunded row: applied=%v err=%v", applied, err)
	}
	failedID := createGuarded("failed", "", false)
	if applied, err := st.MarkStripeWithdrawalPaid(failedID, "", ""); err != nil || applied {
		t.Fatalf("mark failed row: applied=%v err=%v", applied, err)
	}
	detachedID := createGuarded("transferred", "", false)
	if applied, err := st.MarkStripeWithdrawalPaid(detachedID, uniqueID("stale-payout"), ""); err != nil || applied {
		t.Fatalf("mark detached row: applied=%v err=%v", applied, err)
	}
	if _, err := st.MarkStripeWithdrawalPaid(uniqueID("missing-withdrawal"), "", ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("mark missing row err = %v, want ErrNotFound", err)
	}

	reopenPayoutID := uniqueID("reopen-payout")
	reopenID := createGuarded("paid", reopenPayoutID, false)
	if applied, err := st.ReopenStripeWithdrawalAfterPayoutFailure(reopenID, "payout_failed: bounce", true); err != nil || !applied {
		t.Fatalf("reopen live row: applied=%v err=%v", applied, err)
	}
	reopened, err := st.GetStripeWithdrawal(reopenID)
	if err != nil ||
		reopened.Status != "transferred" ||
		reopened.PayoutID != "" ||
		reopened.FailureReason != "payout_failed: bounce" ||
		!reopened.FeeRefunded {
		t.Fatalf("reopened row = %+v err=%v", reopened, err)
	}
	if _, err := st.GetStripeWithdrawalByPayoutID(reopenPayoutID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("reopened payout lookup err = %v, want ErrNotFound", err)
	}
	if applied, err := st.ReopenStripeWithdrawalAfterPayoutFailure(refundedID, "x", false); err != nil || applied {
		t.Fatalf("reopen refunded row: applied=%v err=%v", applied, err)
	}
	if applied, err := st.ReopenStripeWithdrawalAfterPayoutFailure(failedID, "x", false); err != nil || applied {
		t.Fatalf("reopen failed row: applied=%v err=%v", applied, err)
	}
}

func containsWithdrawal(rows []StripeWithdrawal, id string) bool {
	for _, row := range rows {
		if row.ID == id {
			return true
		}
	}
	return false
}
