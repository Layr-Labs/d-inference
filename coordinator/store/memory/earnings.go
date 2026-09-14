package memory

import (
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *Store) RecordProviderEarning(earning *contracts.ProviderEarning) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Idempotency guard mirroring the postgres ON CONFLICT (job_id) DO NOTHING:
	// a retried settlement with the same non-empty job_id is a no-op.
	if earning.JobID != "" {
		for i := range s.providerEarnings {
			if s.providerEarnings[i].JobID == earning.JobID {
				return nil
			}
		}
	}

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
func (s *Store) GetProviderEarnings(providerKey string, limit int) ([]contracts.ProviderEarning, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var results []contracts.ProviderEarning
	for i := len(s.providerEarnings) - 1; i >= 0; i-- {
		if s.providerEarnings[i].ProviderKey == providerKey {
			results = append(results, s.providerEarnings[i])
			if limit > 0 && len(results) >= limit {
				break
			}
		}
	}
	if results == nil {
		return []contracts.ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *Store) GetAccountEarnings(accountID string, limit int) ([]contracts.ProviderEarning, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var results []contracts.ProviderEarning
	for i := len(s.providerEarnings) - 1; i >= 0; i-- {
		if s.providerEarnings[i].AccountID == accountID {
			results = append(results, s.providerEarnings[i])
			if limit > 0 && len(results) >= limit {
				break
			}
		}
	}
	if results == nil {
		return []contracts.ProviderEarning{}, nil
	}
	return results, nil
}

// GetProviderEarningsSummary returns lifetime aggregates for a provider node.
func (s *Store) GetProviderEarningsSummary(providerKey string) (contracts.ProviderEarningsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var summary contracts.ProviderEarningsSummary
	for _, earning := range s.providerEarnings {
		if earning.ProviderKey != providerKey {
			continue
		}
		summary.TotalMicroUSD += earning.AmountMicroUSD
		// base_reward rows add money but are not inference jobs.
		if earning.Model != "base_reward" {
			summary.Count++
			summary.PromptTokens += int64(earning.PromptTokens)
			summary.CompletionTokens += int64(earning.CompletionTokens)
		}
	}

	return summary, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
func (s *Store) GetAccountEarningsSummary(accountID string) (contracts.ProviderEarningsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var summary contracts.ProviderEarningsSummary
	for _, earning := range s.providerEarnings {
		if earning.AccountID != accountID {
			continue
		}
		summary.TotalMicroUSD += earning.AmountMicroUSD
		// base_reward rows add money but are not inference jobs.
		if earning.Model != "base_reward" {
			summary.Count++
			summary.PromptTokens += int64(earning.PromptTokens)
			summary.CompletionTokens += int64(earning.CompletionTokens)
		}
	}

	return summary, nil
}

// RecordProviderPayout stores a payout record for a provider wallet.
func (s *Store) RecordProviderPayout(payout *contracts.ProviderPayout) error {
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
func (s *Store) ListProviderPayouts() ([]contracts.ProviderPayout, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if len(s.providerPayouts) == 0 {
		return []contracts.ProviderPayout{}, nil
	}

	out := make([]contracts.ProviderPayout, len(s.providerPayouts))
	copy(out, s.providerPayouts)
	return out, nil
}

// SettleProviderPayout marks a provider payout as settled.
func (s *Store) SettleProviderPayout(id int64) error {
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
func (s *Store) CreditProviderAccount(earning *contracts.ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Idempotency guard mirroring the postgres ON CONFLICT (job_id) DO NOTHING:
	// a retried settlement with the same non-empty job_id must not double-credit
	// the balance, the withdrawable subset, the ledger, or the earnings summary.
	if earning.JobID != "" {
		for i := range s.providerEarnings {
			if s.providerEarnings[i].JobID == earning.JobID {
				return nil
			}
		}
	}

	cp := *earning
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}

	s.creditLocked(cp.AccountID, cp.AmountMicroUSD, contracts.LedgerPayout, cp.JobID, cp.CreatedAt)
	s.withdrawable[cp.AccountID] += cp.AmountMicroUSD
	s.providerEarningsSeq++
	cp.ID = s.providerEarningsSeq
	s.providerEarnings = append(s.providerEarnings, cp)
	return nil
}

// CreditProviderWallet atomically credits an unlinked provider wallet and
// records the corresponding payout history row.
func (s *Store) CreditProviderWallet(payout *contracts.ProviderPayout) error {
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

	s.creditLocked(cp.ProviderAddress, cp.AmountMicroUSD, contracts.LedgerPayout, cp.JobID, cp.Timestamp)
	s.withdrawable[cp.ProviderAddress] += cp.AmountMicroUSD
	s.providerPayoutSeq++
	cp.ID = s.providerPayoutSeq
	s.providerPayouts = append(s.providerPayouts, cp)
	return nil
}
