// Package payments provides balance tracking and pricing for Darkbloom inference.
//
// The payment flow:
//  1. Consumer pays via Stripe Checkout — webhook credits internal balance
//  2. Consumer makes inference requests — the coordinator debits per-request
//     based on output token count
//  3. Provider earns a payout (total cost minus 10% platform fee)
//  4. Payouts are settled via Stripe Connect Express (bank/card withdrawals)
//
// All amounts are in micro-USD (1 USD = 1,000,000 micro-USD).
//
// The Ledger wraps a Store for balance persistence and adds in-memory tracking
// of per-consumer usage history.
package payments

import (
	"fmt"
	"sync"
	"time"

	"github.com/darkbloom/coordinator/internal/store"
)

// Payout is the persisted provider wallet payout record.
type Payout = store.ProviderPayout

// UsageEntry records a single inference charge for usage history.
type UsageEntry struct {
	JobID            string    `json:"job_id"`
	Model            string    `json:"model"`
	PromptTokens     int       `json:"prompt_tokens"`
	CompletionTokens int       `json:"completion_tokens"`
	CostMicroUSD     int64     `json:"cost_micro_usd"`
	Timestamp        time.Time `json:"timestamp"`
}

// Ledger tracks consumer and provider balances, backed by a Store for
// persistence. The Store handles balance atomicity and ledger entry recording.
type Ledger struct {
	mu    sync.RWMutex
	store store.Store

	// in-memory usage log per consumer (keyed by consumer ID)
	usage map[string][]UsageEntry
}

// NewLedger creates a new Ledger backed by the given Store.
func NewLedger(s store.Store) *Ledger {
	return &Ledger{
		store: s,
		usage: make(map[string][]UsageEntry),
	}
}

// Deposit credits a consumer's balance.
func (l *Ledger) Deposit(consumerID string, amountMicroUSD int64) error {
	return l.store.Credit(consumerID, amountMicroUSD, store.LedgerDeposit, "")
}

// Charge debits a consumer's balance for inference. Returns an error if
// the consumer has insufficient funds.
func (l *Ledger) Charge(consumerID string, amountMicroUSD int64, jobID string) error {
	return l.store.Debit(consumerID, amountMicroUSD, store.LedgerCharge, jobID)
}

// Balance returns the current balance for a consumer in micro-USD.
func (l *Ledger) Balance(consumerID string) int64 {
	return l.store.GetBalance(consumerID)
}

// LedgerHistory returns the full ledger history for an account.
func (l *Ledger) LedgerHistory(consumerID string) []store.LedgerEntry {
	return l.store.LedgerHistory(consumerID)
}

// CreditProvider records a pending payout to a provider.
func (l *Ledger) CreditProvider(providerAddr string, amountMicroUSD int64, model, jobID string) error {
	return l.store.CreditProviderWallet(&store.ProviderPayout{
		ProviderAddress: providerAddr,
		AmountMicroUSD:  amountMicroUSD,
		Model:           model,
		JobID:           jobID,
		Timestamp:       time.Now(),
		Settled:         false,
	})
}

// RecordUsage appends a usage entry for a consumer's history.
func (l *Ledger) RecordUsage(consumerID string, entry UsageEntry) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.usage[consumerID] = append(l.usage[consumerID], entry)
}

// Usage returns a copy of usage history for a consumer.
func (l *Ledger) Usage(consumerID string) []UsageEntry {
	l.mu.RLock()
	defer l.mu.RUnlock()

	entries := l.usage[consumerID]
	if entries == nil {
		return []UsageEntry{}
	}
	out := make([]UsageEntry, len(entries))
	copy(out, entries)
	return out
}

// PendingPayouts returns a copy of all unsettled payouts.
func (l *Ledger) PendingPayouts() []Payout {
	payouts, err := l.store.ListProviderPayouts()
	if err != nil {
		return []Payout{}
	}

	var out []Payout
	for _, p := range payouts {
		if !p.Settled {
			out = append(out, p)
		}
	}
	if out == nil {
		return []Payout{}
	}
	return out
}

// AllPayouts returns a copy of all payouts (settled and unsettled).
func (l *Ledger) AllPayouts() []Payout {
	payouts, err := l.store.ListProviderPayouts()
	if err != nil {
		return []Payout{}
	}
	return payouts
}

// SettlePayout marks the payout at the given index as settled.
func (l *Ledger) SettlePayout(index int) error {
	payouts, err := l.store.ListProviderPayouts()
	if err != nil {
		return fmt.Errorf("list payouts: %w", err)
	}
	if index < 0 || index >= len(payouts) {
		return fmt.Errorf("payout index %d out of range (have %d payouts)", index, len(payouts))
	}
	if payouts[index].Settled {
		return fmt.Errorf("payout at index %d is already settled", index)
	}
	return l.store.SettleProviderPayout(payouts[index].ID)
}
