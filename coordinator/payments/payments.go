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
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
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

// usageHistoryLimit bounds the in-memory usage history kept per consumer. It
// matches the store's UsageByConsumer page (LIMIT 100), which is what
// GET /v1/payments/usage falls back to when the in-memory list is empty, so
// both paths return the same amount of history. Before this bound the slice
// grew by one entry per completion for the life of the process (~440 MB/day
// in production, ~80 % of the live heap after two days) and every GC cycle
// had to mark all of it.
const usageHistoryLimit = 100

// Ledger tracks consumer and provider balances, backed by a Store for
// persistence. The Store handles balance atomicity and ledger entry recording.
type Ledger struct {
	mu    sync.RWMutex
	store store.Store

	// in-memory usage log per consumer (keyed by consumer ID), oldest first,
	// at most usageHistoryLimit entries. The backing array grows with the
	// consumer's history up to the limit and is then shifted in place, so a
	// consumer's footprint is proportional to its entries and never exceeds
	// the limit (see RecordUsage). Nothing evicts an inactive consumer.
	usage map[string][]UsageEntry
}

// NewLedger creates a new Ledger backed by the given Store.
func NewLedger(s store.Store) *Ledger {
	return &Ledger{
		store: s,
		usage: make(map[string][]UsageEntry),
	}
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

// RecordUsage appends a usage entry for a consumer's history, keeping only the
// newest usageHistoryLimit entries in insertion order.
//
// The backing array starts at one entry and doubles as the consumer's history
// grows, never past the limit: the consumer map is never pruned, so a
// low-volume account must cost its entries, not a full 100-entry array
// (~8 KiB) from its first request. Once full, the slice is shifted in place
// (copy(s, s[1:])) before the new entry is written into the last slot. Never
// use append(s[1:], entry) here: reslicing off the front leaks the dropped
// prefix until the next growth and reallocates the whole backing array every
// call once the slice is full, which defeats the bound.
func (l *Ledger) RecordUsage(consumerID string, entry UsageEntry) {
	l.mu.Lock()
	defer l.mu.Unlock()
	entries := l.usage[consumerID]
	if len(entries) < usageHistoryLimit {
		if len(entries) == cap(entries) {
			grown := make([]UsageEntry, len(entries), usageHistoryGrowth(cap(entries)))
			copy(grown, entries)
			entries = grown
		}
		l.usage[consumerID] = append(entries, entry)
		return
	}
	copy(entries, entries[1:])
	entries[len(entries)-1] = entry
	l.usage[consumerID] = entries
}

// usageHistoryGrowth returns the next backing-array capacity for a consumer's
// usage history: double the current one (from 1), capped at usageHistoryLimit.
func usageHistoryGrowth(current int) int {
	next := 2 * current
	if next == 0 {
		next = 1
	}
	if next > usageHistoryLimit {
		next = usageHistoryLimit
	}
	return next
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

// AllPayouts returns a copy of all payouts (settled and unsettled).
func (l *Ledger) AllPayouts() []Payout {
	payouts, err := l.store.ListProviderPayouts()
	if err != nil {
		return []Payout{}
	}
	return payouts
}
