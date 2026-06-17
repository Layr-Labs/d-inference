package store

import (
	"fmt"
	"time"
)

// KeyCount returns the number of active API keys.
func (s *MemoryStore) KeyCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n := 0
	for _, rec := range s.keyRecords {
		if !rec.Disabled {
			n++
		}
	}
	return n
}

// GetBalance returns the current balance in micro-USD for an account.
func (s *MemoryStore) GetBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID]
}

// GetWithdrawableBalance returns the withdrawable balance in micro-USD.
func (s *MemoryStore) GetWithdrawableBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.withdrawable[accountID]
}

// GetBalanceWithWithdrawable returns both balances under a single lock.
func (s *MemoryStore) GetBalanceWithWithdrawable(accountID string) (int64, int64) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID], s.withdrawable[accountID]
}

// Credit adds micro-USD to an account and records a ledger entry.
func (s *MemoryStore) Credit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	return nil
}

// CreditWithdrawable adds micro-USD to both the total balance and the
// withdrawable balance, and records a ledger entry.
func (s *MemoryStore) CreditWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	s.withdrawable[accountID] += amountMicroUSD
	return nil
}

// DebitWithdrawable subtracts micro-USD from both the total balance and
// the withdrawable balance. Returns error if withdrawable is insufficient.
func (s *MemoryStore) DebitWithdrawable(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.withdrawable[accountID] < amountMicroUSD {
		return fmt.Errorf("insufficient withdrawable balance: have %d, need %d micro-USD", s.withdrawable[accountID], amountMicroUSD)
	}
	if s.balances[accountID] < amountMicroUSD {
		return fmt.Errorf("insufficient balance: have %d, need %d micro-USD", s.balances[accountID], amountMicroUSD)
	}

	s.balances[accountID] -= amountMicroUSD
	s.withdrawable[accountID] -= amountMicroUSD
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

// Debit subtracts micro-USD from an account. Returns ErrInsufficientBalance
// if the account has insufficient funds.
func (s *MemoryStore) Debit(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.balances[accountID] < amountMicroUSD {
		return ErrInsufficientBalance
	}

	s.balances[accountID] -= amountMicroUSD
	if s.withdrawable[accountID] > s.balances[accountID] {
		s.withdrawable[accountID] = s.balances[accountID]
	}
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

// MigrateAccountBalance moves the full balance (and its withdrawable subset)
// from one account ID to another, atomically under the store lock.
func (s *MemoryStore) MigrateAccountBalance(from, to string) (bool, error) {
	if from == "" || to == "" || from == to {
		return false, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	bal := s.balances[from]
	wdr := s.withdrawable[from]
	if bal == 0 && wdr == 0 {
		return false, nil
	}
	now := time.Now()

	// Debit the source to zero and credit the destination, recording both legs.
	s.balances[from] = 0
	s.withdrawable[from] = 0
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      from,
		Type:           LedgerMigration,
		AmountMicroUSD: -bal,
		BalanceAfter:   0,
		Reference:      "migrate:out",
		CreatedAt:      now,
	})

	s.balances[to] += bal
	s.withdrawable[to] += wdr
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      to,
		Type:           LedgerMigration,
		AmountMicroUSD: bal,
		BalanceAfter:   s.balances[to],
		Reference:      "migrate:in",
		CreatedAt:      now,
	})
	return true, nil
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

func (s *MemoryStore) creditLocked(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, createdAt time.Time) {
	s.balances[accountID] += amountMicroUSD
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      createdAt,
	})
}
