package store

import "time"

func (s *MemoryStore) CreditOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (bool, error) {
	return s.creditOnce(accountID, amountMicroUSD, entryType, reference, false)
}

func (s *MemoryStore) CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) (bool, error) {
	return s.creditOnce(accountID, amountMicroUSD, entryType, reference, true)
}

// creditOnce checks and applies one ledger identity while holding the same
// store lock. Deposits and withdrawable refunds share that atomic boundary.
func (s *MemoryStore) creditOnce(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, withdrawable bool) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.creditOnceLocked(accountID, amountMicroUSD, entryType, reference, withdrawable), nil
}

func (s *MemoryStore) creditWithdrawableOnceLocked(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string) bool {
	return s.creditOnceLocked(accountID, amountMicroUSD, entryType, reference, true)
}

// creditOnceLocked also serves reversal refunds under the caller's store lock.
func (s *MemoryStore) creditOnceLocked(accountID string, amountMicroUSD int64, entryType LedgerEntryType, reference string, withdrawable bool) bool {
	for i := range s.ledgerEntries {
		entry := &s.ledgerEntries[i]
		if entry.AccountID == accountID && entry.Type == entryType && entry.Reference == reference {
			return false
		}
	}
	s.creditLocked(accountID, amountMicroUSD, entryType, reference, time.Now())
	if withdrawable {
		s.withdrawable[accountID] += amountMicroUSD
	}
	return true
}
