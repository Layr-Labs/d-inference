package store

// In-memory implementation of the Store interface.
//
// MemoryStore keeps all data (API keys, usage records, balances, ledger entries)
// in memory protected by a single RWMutex. This is suitable for development,
// testing, and single-instance deployments where persistence across restarts
// is not needed.
//
// API keys are stored as raw strings (no hashing) for simplicity in the
// in-memory implementation. The PostgresStore uses SHA-256 hashing.

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

// Compile-time check that MemoryStore implements Store.
var _ Store = (*MemoryStore)(nil)

// MemoryStore manages API keys, usage records, payments, and balances in memory.
type MemoryStore struct {
	mu            sync.RWMutex
	keys          map[string]bool    // key → valid
	usage         []UsageRecord
	payments      []PaymentRecord
	balances      map[string]int64   // accountID → micro-USD
	ledgerEntries []LedgerEntry
	ledgerSeq     int64              // auto-increment ID
}

// NewMemory creates a new MemoryStore. If adminKey is non-empty it is
// pre-seeded as a valid API key for bootstrapping.
func NewMemory(adminKey string) *MemoryStore {
	s := &MemoryStore{
		keys:          make(map[string]bool),
		usage:         make([]UsageRecord, 0),
		payments:      make([]PaymentRecord, 0),
		balances:      make(map[string]int64),
		ledgerEntries: make([]LedgerEntry, 0),
	}
	if adminKey != "" {
		s.keys[adminKey] = true
	}
	return s
}

// CreateKey generates a cryptographically random API key, stores it, and
// returns it.
func (s *MemoryStore) CreateKey() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	key := "dginf-" + hex.EncodeToString(b)

	s.mu.Lock()
	s.keys[key] = true
	s.mu.Unlock()

	return key, nil
}

// ValidateKey returns true if the given key exists and is valid.
func (s *MemoryStore) ValidateKey(key string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.keys[key]
}

// RevokeKey removes a key from the store. Returns true if the key existed.
func (s *MemoryStore) RevokeKey(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.keys[key] {
		delete(s.keys, key)
		return true
	}
	return false
}

// RecordUsage appends a usage record to the in-memory log.
func (s *MemoryStore) RecordUsage(providerID, consumerKey, model string, promptTokens, completionTokens int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usage = append(s.usage, UsageRecord{
		ProviderID:       providerID,
		ConsumerKey:      consumerKey,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Timestamp:        time.Now(),
	})
}

// RecordPayment appends a payment record to the in-memory log.
func (s *MemoryStore) RecordPayment(txHash, consumerAddr, providerAddr, amountUSD, model string, promptTokens, completionTokens int, memo string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Check for duplicate tx_hash.
	for _, p := range s.payments {
		if p.TxHash == txHash && txHash != "" {
			return fmt.Errorf("duplicate tx_hash: %s", txHash)
		}
	}

	s.payments = append(s.payments, PaymentRecord{
		TxHash:           txHash,
		ConsumerAddress:  consumerAddr,
		ProviderAddress:  providerAddr,
		AmountUSD:        amountUSD,
		Model:            model,
		PromptTokens:     promptTokens,
		CompletionTokens: completionTokens,
		Memo:             memo,
		CreatedAt:        time.Now(),
	})
	return nil
}

// UsageRecords returns a copy of all usage records.
func (s *MemoryStore) UsageRecords() []UsageRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]UsageRecord, len(s.usage))
	copy(out, s.usage)
	return out
}

// KeyCount returns the number of active API keys.
func (s *MemoryStore) KeyCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.keys)
}

// GetBalance returns the current balance in micro-USD for an account.
func (s *MemoryStore) GetBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID]
}

// Credit adds micro-USD to an account and records a ledger entry.
func (s *MemoryStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.balances[accountID] += amountMicroUSD
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      time.Now(),
	})
	return nil
}

// Debit subtracts micro-USD from an account. Returns error if insufficient funds.
func (s *MemoryStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.balances[accountID] < amountMicroUSD {
		return fmt.Errorf("insufficient balance: have %d, need %d micro-USD", s.balances[accountID], amountMicroUSD)
	}

	s.balances[accountID] -= amountMicroUSD
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: -amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      time.Now(),
	})
	return nil
}

// LedgerHistory returns ledger entries for an account, newest first.
func (s *MemoryStore) LedgerHistory(accountID string) []LedgerEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var entries []LedgerEntry
	for i := len(s.ledgerEntries) - 1; i >= 0; i-- {
		if s.ledgerEntries[i].AccountID == accountID {
			entries = append(entries, s.ledgerEntries[i])
		}
	}
	if entries == nil {
		return []LedgerEntry{}
	}
	return entries
}
