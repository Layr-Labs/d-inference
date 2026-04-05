// Package payments provides balance tracking and pricing for EigenInference inference.
//
// The payment flow:
//  1. Consumer deposits USDC on Solana (verified on-chain via JSON-RPC)
//     or pays via Stripe checkout
//  2. Consumer makes inference requests — the coordinator debits per-request
//     based on output token count
//  3. Provider earns a payout (total cost minus 10% platform fee)
//  4. Payouts accumulate and can be settled on-chain
//
// All amounts are in micro-USD (1 USD = 1,000,000 micro-USD). This maps 1:1
// to USDC's 6-decimal on-chain representation.
//
// The Ledger wraps a Store for balance persistence and adds in-memory tracking
// of per-consumer usage history and pending provider payouts.
package payments

import (
	"fmt"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
)

// Payout represents a pending payment obligation to a provider.
type Payout struct {
	ProviderAddress string    `json:"provider_address"`
	AmountMicroUSD  int64     `json:"amount_micro_usd"`
	Model           string    `json:"model"`
	JobID           string    `json:"job_id"`
	Timestamp       time.Time `json:"timestamp"`
	Settled         bool      `json:"settled"`
}

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

	// pending payouts to providers (settled on-chain when ready)
	pendingPayouts []Payout
}

// NewLedger creates a new Ledger backed by the given Store.
func NewLedger(s store.Store) *Ledger {
	return &Ledger{
		store:          s,
		usage:          make(map[string][]UsageEntry),
		pendingPayouts: make([]Payout, 0),
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
func (l *Ledger) CreditProvider(providerAddr string, amountMicroUSD int64, model, jobID string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	// Credit provider balance in the store
	_ = l.store.Credit(providerAddr, amountMicroUSD, store.LedgerPayout, jobID)

	l.pendingPayouts = append(l.pendingPayouts, Payout{
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
	l.mu.RLock()
	defer l.mu.RUnlock()

	var out []Payout
	for _, p := range l.pendingPayouts {
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
	l.mu.RLock()
	defer l.mu.RUnlock()

	out := make([]Payout, len(l.pendingPayouts))
	copy(out, l.pendingPayouts)
	return out
}

// SettlePayout marks the payout at the given index as settled.
func (l *Ledger) SettlePayout(index int) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if index < 0 || index >= len(l.pendingPayouts) {
		return fmt.Errorf("payout index %d out of range (have %d payouts)", index, len(l.pendingPayouts))
	}
	if l.pendingPayouts[index].Settled {
		return fmt.Errorf("payout at index %d is already settled", index)
	}
	l.pendingPayouts[index].Settled = true
	return nil
}
