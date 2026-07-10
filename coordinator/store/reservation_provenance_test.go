package store

import "testing"

func TestDebitReservation_ConsumesNonWithdrawableFirst(t *testing.T) {
	st := NewMemory(Config{AdminKey: "test"})
	// $10 deposit (non-withdrawable) + $5 earnings (withdrawable)
	_ = st.Credit("acct", 10_000_000, LedgerStripeDeposit, "dep")
	_ = st.CreditWithdrawable("acct", 5_000_000, LedgerPayout, "earn")

	reservedWdr, err := st.DebitReservation("acct", 12_000_000, LedgerCharge, "reserve")
	if err != nil {
		t.Fatal(err)
	}
	// Nonwithdrawable 10M consumed first → only 2M from withdrawable.
	if reservedWdr != 2_000_000 {
		t.Fatalf("reservedWithdrawable = %d, want 2_000_000", reservedWdr)
	}
	bal, wdr := st.GetBalanceWithWithdrawable("acct")
	if bal != 3_000_000 {
		t.Fatalf("balance = %d, want 3_000_000", bal)
	}
	if wdr != 3_000_000 {
		t.Fatalf("withdrawable = %d, want 3_000_000", wdr)
	}

	if err := st.CreditReservationRelease("acct", 12_000_000, reservedWdr, LedgerRefund, "release"); err != nil {
		t.Fatal(err)
	}
	bal, wdr = st.GetBalanceWithWithdrawable("acct")
	if bal != 15_000_000 {
		t.Fatalf("balance after release = %d, want 15_000_000", bal)
	}
	if wdr != 5_000_000 {
		t.Fatalf("withdrawable after release = %d, want 5_000_000", wdr)
	}
}

func TestApplyStripeDeposit_IdempotentOnEventAndSession(t *testing.T) {
	st := NewMemory(Config{AdminKey: "test"})
	bs := &BillingSession{
		ID:             "bs-1",
		AccountID:      "acct",
		PaymentMethod:  "stripe",
		AmountMicroUSD: 1_000_000,
		ExternalID:     "cs_123",
		Status:         "pending",
	}
	if err := st.CreateBillingSession(bs); err != nil {
		t.Fatal(err)
	}

	applied, err := st.ApplyStripeDeposit("evt_1", "cs_123", "acct", "bs-1", 1_000_000, LedgerStripeDeposit)
	if err != nil || !applied {
		t.Fatalf("first apply: applied=%v err=%v", applied, err)
	}
	if bal := st.GetBalance("acct"); bal != 1_000_000 {
		t.Fatalf("balance = %d", bal)
	}

	applied, err = st.ApplyStripeDeposit("evt_1", "cs_123", "acct", "bs-1", 1_000_000, LedgerStripeDeposit)
	if err != nil || applied {
		t.Fatalf("same event replay: applied=%v err=%v", applied, err)
	}
	applied, err = st.ApplyStripeDeposit("evt_2", "cs_123", "acct", "bs-1", 1_000_000, LedgerStripeDeposit)
	if err != nil || applied {
		t.Fatalf("same checkout different event: applied=%v err=%v", applied, err)
	}
	if bal := st.GetBalance("acct"); bal != 1_000_000 {
		t.Fatalf("balance after replays = %d, want 1_000_000", bal)
	}
}
