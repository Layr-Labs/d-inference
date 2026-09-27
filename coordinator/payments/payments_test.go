package payments

import (
	"strconv"
	"testing"
	"time"

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

func TestNewLedger(t *testing.T) {
	l := newTestLedger()
	if l == nil {
		t.Fatal("NewLedger returned nil")
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

func TestCreditProviderWallet(t *testing.T) {
	l := newTestLedger()

	if err := l.store.CreditProviderWallet(&store.ProviderPayout{
		ProviderAddress: "0xProvider1",
		AmountMicroUSD:  900_000,
		Model:           "qwen3.5-9b",
		JobID:           "job-123",
		Timestamp:       time.Now(),
	}); err != nil {
		t.Fatalf("CreditProviderWallet(1): %v", err)
	}
	if err := l.store.CreditProviderWallet(&store.ProviderPayout{
		ProviderAddress: "0xProvider2",
		AmountMicroUSD:  450_000,
		Model:           "llama3-8b",
		JobID:           "job-456",
		Timestamp:       time.Now(),
	}); err != nil {
		t.Fatalf("CreditProviderWallet(2): %v", err)
	}

	payouts := l.AllPayouts()
	if len(payouts) != 2 {
		t.Fatalf("payouts = %d, want 2", len(payouts))
	}
	if payouts[0].ProviderAddress != "0xProvider1" {
		t.Errorf("payout[0] address = %q", payouts[0].ProviderAddress)
	}
	if payouts[0].AmountMicroUSD != 900_000 {
		t.Errorf("payout[0] amount = %d", payouts[0].AmountMicroUSD)
	}
	if payouts[0].Settled {
		t.Error("payout[0] should be unsettled")
	}

	// Provider balance should also be tracked in the store
	if bal := l.Balance("0xProvider1"); bal != 900_000 {
		t.Errorf("provider balance = %d, want 900_000", bal)
	}
}

func TestPayoutsPersistAcrossLedgerInstances(t *testing.T) {
	st := store.NewMemory(store.Config{})
	l1 := NewLedger(st)

	if err := l1.store.CreditProviderWallet(&store.ProviderPayout{
		ProviderAddress: "0xProvider1",
		AmountMicroUSD:  900_000,
		Model:           "qwen3.5-9b",
		JobID:           "job-123",
		Timestamp:       time.Now(),
	}); err != nil {
		t.Fatalf("CreditProviderWallet: %v", err)
	}

	l2 := NewLedger(st)
	payouts := l2.AllPayouts()
	if len(payouts) != 1 {
		t.Fatalf("payouts = %d, want 1", len(payouts))
	}
	if payouts[0].JobID != "job-123" {
		t.Fatalf("payout job_id = %q, want job-123", payouts[0].JobID)
	}
	if payouts[0].ProviderAddress != "0xProvider1" {
		t.Fatalf("provider address = %q, want 0xProvider1", payouts[0].ProviderAddress)
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

// TestRecordUsageBoundedHistory pins the in-memory usage history to
// usageHistoryLimit entries per consumer: the newest entries win, insertion
// order is preserved, other consumers are untouched, and the backing array
// never grows past the limit (the cap assertion is what catches an
// append(s[1:], entry) reslice, which keeps len bounded but reallocates and
// leaks the dropped prefix on every call once full).
func TestRecordUsageBoundedHistory(t *testing.T) {
	l := newTestLedger()

	const other = "consumer-other"
	l.RecordUsage(other, UsageEntry{JobID: "other-job", CostMicroUSD: 7})

	const total = 1_000
	for i := range total {
		l.RecordUsage("consumer-1", UsageEntry{
			JobID: "job-" + strconv.Itoa(i), CostMicroUSD: int64(i),
		})
	}

	usage := l.Usage("consumer-1")
	if len(usage) != usageHistoryLimit {
		t.Fatalf("usage entries = %d, want %d", len(usage), usageHistoryLimit)
	}
	for i, e := range usage {
		want := total - usageHistoryLimit + i
		if e.JobID != "job-"+strconv.Itoa(want) || e.CostMicroUSD != int64(want) {
			t.Fatalf("usage[%d] = %q/%d, want job-%d/%d (newest %d in order)",
				i, e.JobID, e.CostMicroUSD, want, want, usageHistoryLimit)
		}
	}

	if got := l.Usage(other); len(got) != 1 || got[0].JobID != "other-job" {
		t.Fatalf("other consumer history = %+v, want the single untouched entry", got)
	}

	// Heap check: 10,000 more records must keep both len AND cap at the limit.
	for i := range 10_000 {
		l.RecordUsage("consumer-1", UsageEntry{JobID: "late-" + strconv.Itoa(i)})
	}
	l.mu.RLock()
	stored := l.usage["consumer-1"]
	l.mu.RUnlock()
	if len(stored) != usageHistoryLimit {
		t.Fatalf("stored len = %d, want %d", len(stored), usageHistoryLimit)
	}
	if cap(stored) > usageHistoryLimit {
		t.Fatalf("stored cap = %d, want <= %d (backing array must not grow)", cap(stored), usageHistoryLimit)
	}
	if stored[usageHistoryLimit-1].JobID != "late-9999" || stored[0].JobID != "late-9900" {
		t.Fatalf("stored window = [%s .. %s], want [late-9900 .. late-9999]",
			stored[0].JobID, stored[usageHistoryLimit-1].JobID)
	}
}

// TestRecordUsageGrowsPerConsumerLazily: the consumer map is never pruned, so
// a consumer's backing array must cost its entries, not the full limit from
// its first request — it doubles from one entry and stops at the limit, after
// which the in-place shift never reallocates.
func TestRecordUsageGrowsPerConsumerLazily(t *testing.T) {
	l := newTestLedger()
	capOf := func(consumerID string) int {
		l.mu.RLock()
		defer l.mu.RUnlock()
		return cap(l.usage[consumerID])
	}

	// Many low-volume consumers: one entry each must not allocate the limit.
	for i := range 1_000 {
		id := "consumer-" + strconv.Itoa(i)
		l.RecordUsage(id, UsageEntry{JobID: "job"})
		if got := capOf(id); got != 1 {
			t.Fatalf("cap after one entry for %s = %d, want 1", id, got)
		}
	}

	// Growth is geometric and never overshoots the limit.
	const heavy = "consumer-heavy"
	for i := 1; i <= usageHistoryLimit; i++ {
		l.RecordUsage(heavy, UsageEntry{JobID: "job-" + strconv.Itoa(i)})
		if got := capOf(heavy); got < i || got > usageHistoryLimit {
			t.Fatalf("cap after %d entries = %d, want in [%d, %d]", i, got, i, usageHistoryLimit)
		}
	}
	if got := capOf(heavy); got != usageHistoryLimit {
		t.Fatalf("cap at the limit = %d, want exactly %d", got, usageHistoryLimit)
	}

	// Full: the shift reuses the same backing array.
	l.mu.RLock()
	before := &l.usage[heavy][0]
	l.mu.RUnlock()
	for i := range 10_000 {
		l.RecordUsage(heavy, UsageEntry{JobID: "late-" + strconv.Itoa(i)})
	}
	l.mu.RLock()
	after := &l.usage[heavy][0]
	stored := l.usage[heavy]
	l.mu.RUnlock()
	if before != after || cap(stored) != usageHistoryLimit || len(stored) != usageHistoryLimit {
		t.Fatalf("full history reallocated: same array=%v len=%d cap=%d, want same array at %d/%d",
			before == after, len(stored), cap(stored), usageHistoryLimit, usageHistoryLimit)
	}
	if got := l.Usage(heavy); got[0].JobID != "late-9900" || got[usageHistoryLimit-1].JobID != "late-9999" {
		t.Fatalf("history window = [%s .. %s], want [late-9900 .. late-9999]", got[0].JobID, got[usageHistoryLimit-1].JobID)
	}
}
