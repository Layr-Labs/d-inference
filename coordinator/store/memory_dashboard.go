package store

import (
	"context"
	"time"
)

// AccountEarningsWindows aggregates the account's last-24h and last-7d rows.
func (s *MemoryStore) AccountEarningsWindows(accountID string, now time.Time) (AccountEarningsWindows, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	cutoff24h := now.Add(-24 * time.Hour)
	cutoff7d := now.Add(-7 * 24 * time.Hour)
	var w AccountEarningsWindows
	for _, e := range s.providerEarnings {
		if e.AccountID != accountID || e.CreatedAt.Before(cutoff7d) {
			continue
		}
		w.Last7dJobs++
		w.Last7dMicroUSD += e.AmountMicroUSD
		if !e.CreatedAt.Before(cutoff24h) {
			w.Last24hJobs++
			w.Last24hMicroUSD += e.AmountMicroUSD
		}
	}
	return w, nil
}

func (s *MemoryStore) GetReputations(_ context.Context, providerIDs []string) (map[string]*ReputationRecord, error) {
	out := make(map[string]*ReputationRecord, len(providerIDs))
	if len(providerIDs) == 0 {
		return out, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, id := range providerIDs {
		if rep, ok := s.reputationRecords[id]; ok {
			cp := *rep
			out[id] = &cp
		}
	}
	return out, nil
}
