package memory

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// GetBalance returns the current balance in micro-USD for an account.
func (s *Store) GetBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID]
}

// GetWithdrawableBalance returns the withdrawable balance in micro-USD.
func (s *Store) GetWithdrawableBalance(accountID string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.withdrawable[accountID]
}

// GetBalanceWithWithdrawable returns both balances under a single lock.
func (s *Store) GetBalanceWithWithdrawable(accountID string) (int64, int64) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.balances[accountID], s.withdrawable[accountID]
}

// Credit adds micro-USD to an account and records a ledger entry.
func (s *Store) Credit(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	return nil
}

// CreditWithdrawable adds micro-USD to both the total balance and the
// withdrawable balance, and records a ledger entry.
func (s *Store) CreditWithdrawable(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	s.withdrawable[accountID] += amountMicroUSD
	return nil
}

// CreditWithdrawableOnce credits only if no ledger entry with the same
// (entryType, reference) exists yet.
func (s *Store) CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.ledgerEntries {
		if s.ledgerEntries[i].AccountID == accountID &&
			s.ledgerEntries[i].Type == entryType &&
			s.ledgerEntries[i].Reference == reference {
			return false, nil
		}
	}
	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	s.withdrawable[accountID] += amountMicroUSD
	return true, nil
}

// DebitWithdrawable subtracts micro-USD from both the total balance and
// the withdrawable balance. Returns error if withdrawable is insufficient.
func (s *Store) DebitWithdrawable(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) error {
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
	s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{
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
func (s *Store) Debit(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.balances[accountID] < amountMicroUSD {
		return contracts.ErrInsufficientBalance
	}

	s.balances[accountID] -= amountMicroUSD
	if s.withdrawable[accountID] > s.balances[accountID] {
		s.withdrawable[accountID] = s.balances[accountID]
	}
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{
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
func (s *Store) MigrateAccountBalance(from, to string) (bool, error) {
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
	s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      from,
		Type:           contracts.LedgerMigration,
		AmountMicroUSD: -bal,
		BalanceAfter:   0,
		Reference:      "migrate:out",
		CreatedAt:      now,
	})

	s.balances[to] += bal
	s.withdrawable[to] += wdr
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      to,
		Type:           contracts.LedgerMigration,
		AmountMicroUSD: bal,
		BalanceAfter:   s.balances[to],
		Reference:      "migrate:in",
		CreatedAt:      now,
	})
	return true, nil
}

// LedgerHistory returns ledger entries for an account, newest first.
func (s *Store) LedgerHistory(accountID string) []contracts.LedgerEntry {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var entries []contracts.LedgerEntry
	for i := len(s.ledgerEntries) - 1; i >= 0; i-- {
		if s.ledgerEntries[i].AccountID == accountID {
			entries = append(entries, s.ledgerEntries[i])
		}
	}
	if entries == nil {
		return []contracts.LedgerEntry{}
	}
	return entries
}

func (s *Store) creditLocked(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string, createdAt time.Time) {
	s.balances[accountID] += amountMicroUSD
	s.ledgerSeq++
	s.ledgerEntries = append(s.ledgerEntries, contracts.LedgerEntry{
		ID:             s.ledgerSeq,
		AccountID:      accountID,
		Type:           entryType,
		AmountMicroUSD: amountMicroUSD,
		BalanceAfter:   s.balances[accountID],
		Reference:      reference,
		CreatedAt:      createdAt,
	})
}
