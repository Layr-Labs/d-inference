package memory

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"time"
)

func (s *Store) CreditOnce(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) (bool, error) {
	return s.creditOnce(accountID, amountMicroUSD, entryType, reference, false)
}

func (s *Store) CreditWithdrawableOnce(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) (bool, error) {
	return s.creditOnce(accountID, amountMicroUSD, entryType, reference, true)
}

// creditOnce checks and applies one ledger identity while holding the same
// store lock. Deposits and withdrawable refunds share that atomic boundary.
func (s *Store) creditOnce(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string, withdrawable bool) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.creditOnceLocked(accountID, amountMicroUSD, entryType, reference, withdrawable), nil
}

func (s *Store) creditWithdrawableOnceLocked(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string) bool {
	return s.creditOnceLocked(accountID, amountMicroUSD, entryType, reference, true)
}

// creditOnceLocked also serves reversal refunds under the caller's store lock.
func (s *Store) creditOnceLocked(accountID string, amountMicroUSD int64, entryType contracts.LedgerEntryType, reference string, withdrawable bool) bool {
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
