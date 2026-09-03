package payments

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func newTestLedger() *Ledger {
	return NewLedger(store.NewMemory(store.Config{}))
}

// creditBalance funds a test account the way production does (Stripe webhook →
// store.Credit); the Ledger has no deposit method of its own.
func creditBalance(t *testing.T, l *Ledger, consumerID string, amountMicroUSD int64) {
	t.Helper()
	if err := l.store.Credit(consumerID, amountMicroUSD, store.LedgerDeposit, ""); err != nil {
		t.Fatalf("credit %s: %v", consumerID, err)
	}
}

func TestBalance(t *testing.T) {
	l := newTestLedger()

	if bal := l.Balance("0xConsumer1"); bal != 0 {
		t.Errorf("initial balance = %d, want 0", bal)
	}

	creditBalance(t, l, "0xConsumer1", 10_000_000)
	if bal := l.Balance("0xConsumer1"); bal != 10_000_000 {
		t.Errorf("balance after credit = %d, want 10_000_000", bal)
	}

	creditBalance(t, l, "0xConsumer1", 5_000_000)
	if bal := l.Balance("0xConsumer1"); bal != 15_000_000 {
		t.Errorf("balance after second credit = %d, want 15_000_000", bal)
	}
}

func TestCharge(t *testing.T) {
	l := newTestLedger()
	creditBalance(t, l, "0xConsumer1", 10_000_000)

	if err := l.Charge("0xConsumer1", 3_000_000, "job-1"); err != nil {
		t.Fatalf("Charge: %v", err)
	}
	if bal := l.Balance("0xConsumer1"); bal != 7_000_000 {
		t.Errorf("balance after charge = %d, want 7_000_000", bal)
	}

	if err := l.Charge("0xConsumer1", 7_000_000, "job-2"); err != nil {
		t.Fatalf("Charge exact balance: %v", err)
	}
	if bal := l.Balance("0xConsumer1"); bal != 0 {
		t.Errorf("balance should be 0, got %d", bal)
	}
}

func TestChargeInsufficientFunds(t *testing.T) {
	l := newTestLedger()
	creditBalance(t, l, "0xConsumer1", 1_000_000)

	err := l.Charge("0xConsumer1", 2_000_000, "job-1")
	if err == nil {
		t.Fatal("expected error for insufficient funds")
	}

	if bal := l.Balance("0xConsumer1"); bal != 1_000_000 {
		t.Errorf("balance should be unchanged after failed charge, got %d", bal)
	}
}

func TestChargeNoAccount(t *testing.T) {
	l := newTestLedger()

	err := l.Charge("0xNobody", 1_000, "job-1")
	if err == nil {
		t.Fatal("expected error for non-existent account")
	}
}

func TestRecordAndGetUsage(t *testing.T) {
	l := newTestLedger()

	l.RecordUsage("consumer-1", UsageEntry{
		JobID: "job-1", Model: "qwen3.5-9b",
		PromptTokens: 100, CompletionTokens: 50, CostMicroUSD: 1_000,
	})
	l.RecordUsage("consumer-1", UsageEntry{
		JobID: "job-2", Model: "llama3-8b",
		PromptTokens: 200, CompletionTokens: 100, CostMicroUSD: 1_000,
	})

	usage := l.Usage("consumer-1")
	if len(usage) != 2 {
		t.Fatalf("usage entries = %d, want 2", len(usage))
	}
	if usage[0].JobID != "job-1" {
		t.Errorf("usage[0].JobID = %q", usage[0].JobID)
	}
}

func TestUsageEmpty(t *testing.T) {
	l := newTestLedger()
	usage := l.Usage("nonexistent")
	if usage == nil {
		t.Fatal("Usage should return empty slice, not nil")
	}
	if len(usage) != 0 {
		t.Errorf("usage entries = %d, want 0", len(usage))
	}
}

func TestUsageReturnsCopy(t *testing.T) {
	l := newTestLedger()
	l.RecordUsage("c1", UsageEntry{JobID: "j1", CostMicroUSD: 1000})

	usage := l.Usage("c1")
	usage[0].CostMicroUSD = 999999

	original := l.Usage("c1")
	if original[0].CostMicroUSD != 1000 {
		t.Error("Usage should return a copy")
	}
}

func TestAllPayoutsEmpty(t *testing.T) {
	l := newTestLedger()
	payouts := l.AllPayouts()
	if payouts == nil {
		t.Fatal("AllPayouts should return empty slice, not nil")
	}
	if len(payouts) != 0 {
		t.Errorf("payouts = %d, want 0", len(payouts))
	}
}

func TestMultipleConsumers(t *testing.T) {
	l := newTestLedger()

	creditBalance(t, l, "c1", 5_000_000)
	creditBalance(t, l, "c2", 10_000_000)

	if l.Balance("c1") != 5_000_000 {
		t.Errorf("c1 balance = %d", l.Balance("c1"))
	}
	if l.Balance("c2") != 10_000_000 {
		t.Errorf("c2 balance = %d", l.Balance("c2"))
	}

	if err := l.Charge("c1", 2_000_000, "job-1"); err != nil {
		t.Fatalf("Charge: %v", err)
	}
	if l.Balance("c1") != 3_000_000 {
		t.Errorf("c1 balance after charge = %d", l.Balance("c1"))
	}
	if l.Balance("c2") != 10_000_000 {
		t.Errorf("c2 balance should be unchanged = %d", l.Balance("c2"))
	}
}

func TestLedgerHistory(t *testing.T) {
	l := newTestLedger()

	creditBalance(t, l, "c1", 10_000_000)
	if err := l.Charge("c1", 3_000_000, "job-1"); err != nil {
		t.Fatalf("Charge: %v", err)
	}
	creditBalance(t, l, "c1", 2_000_000)

	history := l.LedgerHistory("c1")
	if len(history) != 3 {
		t.Fatalf("ledger entries = %d, want 3", len(history))
	}

	// Newest first
	if history[0].Type != store.LedgerDeposit {
		t.Errorf("entry[0] type = %q, want deposit", history[0].Type)
	}
	if history[0].BalanceAfter != 9_000_000 {
		t.Errorf("entry[0] balance_after = %d, want 9_000_000", history[0].BalanceAfter)
	}
	if history[1].Type != store.LedgerCharge {
		t.Errorf("entry[1] type = %q, want charge", history[1].Type)
	}
}
