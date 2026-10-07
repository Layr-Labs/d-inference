package memory

import (
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// RecordProviderEarning stores an earning record for a specific provider node.
func (s *MemoryStore) RecordProviderEarning(earning *store.ProviderEarning) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Idempotency guard mirroring the postgres ON CONFLICT (job_id) DO NOTHING:
	// a retried settlement with the same non-empty job_id is a no-op.
	if earning.JobID != "" {
		for i := range s.history.ProviderEarnings {
			if s.history.ProviderEarnings[i].JobID == earning.JobID {
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
	s.history.ProviderEarnings = append(s.history.ProviderEarnings, cp)
	return nil
}

// GetAccountEarnings returns all earnings across all nodes for an account, newest first.
func (s *MemoryStore) GetAccountEarnings(accountID string, limit int) ([]store.ProviderEarning, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var results []store.ProviderEarning
	for i := len(s.history.ProviderEarnings) - 1; i >= 0; i-- {
		if s.history.ProviderEarnings[i].AccountID == accountID {
			results = append(results, s.history.ProviderEarnings[i])
			if limit > 0 && len(results) >= limit {
				break
			}
		}
	}
	if results == nil {
		return []store.ProviderEarning{}, nil
	}
	return results, nil
}

// GetAccountEarningsSummary returns lifetime aggregates for an account.
func (s *MemoryStore) GetAccountEarningsSummary(accountID string) (store.ProviderEarningsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var summary store.ProviderEarningsSummary
	for _, earning := range s.history.ProviderEarnings {
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

// CreditProviderAccount atomically credits a linked provider account and records
// the corresponding per-node earning.
func (s *MemoryStore) CreditProviderAccount(earning *store.ProviderEarning) error {
	if earning == nil {
		return errors.New("provider earning is required")
	}
	if earning.AccountID == "" {
		return errors.New("provider earning account_id is required")
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	return s.creditProviderAccountLocked(earning)
}

func (s *MemoryStore) creditProviderAccountLocked(earning *store.ProviderEarning) error {

	// Idempotency guard mirroring the postgres ON CONFLICT (job_id) DO NOTHING:
	// a retried settlement with the same non-empty job_id must not double-credit
	// the balance, the withdrawable subset, the ledger, or the earnings summary.
	if earning.JobID != "" {
		for i := range s.history.ProviderEarnings {
			if s.history.ProviderEarnings[i].JobID == earning.JobID {
				return nil
			}
		}
	}

	cp := *earning
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}

	if s.creditLocked(cp.AccountID, cp.AmountMicroUSD, store.LedgerPayout, cp.JobID, cp.CreatedAt) {
		s.withdrawable[cp.AccountID] += cp.AmountMicroUSD
	}
	s.providerEarningsSeq++
	cp.ID = s.providerEarningsSeq
	s.history.ProviderEarnings = append(s.history.ProviderEarnings, cp)
	return nil
}
