package store

import (
	"errors"
	"fmt"
	"time"
)

// --- Provider Earnings ---

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *MemoryStore) RecordProviderEarning(earning *ProviderEarning) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.providerEarningsSeq++
	cp := *earning
	cp.ID = s.providerEarningsSeq
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	s.providerEarnings = append(s.providerEarnings, cp)
	return nil
}

// GetProviderEarnings returns earnings for a specific provider node (by public key), newest first.
func (s *MemoryStore) GetProviderEarnings(providerKey string, limit int) ([]ProviderEarning, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var results []ProviderEarning
	for i := len(s.providerEarnings) - 1; i >= 0; i-- {
		if s.providerEarnings[i].ProviderKey == providerKey {
			results = append(results, s.providerEarnings[i])
			if limit > 0 && len(results) >= limit {
				break
			}
		}
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *MemoryStore) GetAccountEarnings(accountID string, limit int) ([]ProviderEarning, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var results []ProviderEarning
	for i := len(s.providerEarnings) - 1; i >= 0; i-- {
		if s.providerEarnings[i].AccountID == accountID {
			results = append(results, s.providerEarnings[i])
			if limit > 0 && len(results) >= limit {
				break
			}
		}
	}
	if results == nil {
		return []ProviderEarning{}, nil
	}
	return results, nil
}

// GetProviderEarningsSummary returns lifetime aggregates for a provider node.
func (s *MemoryStore) GetProviderEarningsSummary(providerKey string) (ProviderEarningsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var summary ProviderEarningsSummary
	for _, earning := range s.providerEarnings {
		if earning.ProviderKey != providerKey {
			continue
		}
		summary.Count++
		summary.TotalMicroUSD += earning.AmountMicroUSD
		summary.PromptTokens += int64(earning.PromptTokens)
		summary.CompletionTokens += int64(earning.CompletionTokens)
	}

	return summary, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
func (s *MemoryStore) GetAccountEarningsSummary(accountID string) (ProviderEarningsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var summary ProviderEarningsSummary
	for _, earning := range s.providerEarnings {
		if earning.AccountID != accountID {
			continue
		}
		summary.Count++
		summary.TotalMicroUSD += earning.AmountMicroUSD
		summary.PromptTokens += int64(earning.PromptTokens)
		summary.CompletionTokens += int64(earning.CompletionTokens)
	}

	return summary, nil
}

// RecordProviderPayout stores a payout record for a provider wallet.
func (s *MemoryStore) RecordProviderPayout(payout *ProviderPayout) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.providerPayoutSeq++
	cp := *payout
	cp.ID = s.providerPayoutSeq
	if cp.Timestamp.IsZero() {
		cp.Timestamp = time.Now()
	}
	s.providerPayouts = append(s.providerPayouts, cp)
	return nil
}

// ListProviderPayouts returns all provider payout records in creation order.
func (s *MemoryStore) ListProviderPayouts() ([]ProviderPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.providerPayouts) == 0 {
		return []ProviderPayout{}, nil
	}

	out := make([]ProviderPayout, len(s.providerPayouts))
	copy(out, s.providerPayouts)
	return out, nil
}

// SettleProviderPayout marks a provider payout as settled.
func (s *MemoryStore) SettleProviderPayout(id int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i := range s.providerPayouts {
		if s.providerPayouts[i].ID != id {
			continue
		}
		if s.providerPayouts[i].Settled {
			return fmt.Errorf("provider payout %d already settled", id)
		}
		s.providerPayouts[i].Settled = true
		return nil
	}

	return fmt.Errorf("provider payout %d not found", id)
}

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
func (s *MemoryStore) CreditProviderAccount(earning *ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *earning
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}

	s.creditLocked(cp.AccountID, cp.AmountMicroUSD, LedgerPayout, cp.JobID, cp.CreatedAt)
	s.withdrawable[cp.AccountID] += cp.AmountMicroUSD
	s.providerEarningsSeq++
	cp.ID = s.providerEarningsSeq
	s.providerEarnings = append(s.providerEarnings, cp)
	return nil
}

// CreditProviderWallet atomically credits an unlinked provider wallet and
// records the corresponding payout history row.
func (s *MemoryStore) CreditProviderWallet(payout *ProviderPayout) error {
	if payout == nil {
		return errors.New("provider payout is required")
	}
	if payout.ProviderAddress == "" {
		return errors.New("provider payout address is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *payout
	if cp.Timestamp.IsZero() {
		cp.Timestamp = time.Now()
	}

	s.creditLocked(cp.ProviderAddress, cp.AmountMicroUSD, LedgerPayout, cp.JobID, cp.Timestamp)
	s.withdrawable[cp.ProviderAddress] += cp.AmountMicroUSD
	s.providerPayoutSeq++
	cp.ID = s.providerPayoutSeq
	s.providerPayouts = append(s.providerPayouts, cp)
	return nil
}
