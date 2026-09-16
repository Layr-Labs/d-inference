package memory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

// AccountEarningsWindows aggregates the account's last-24h and last-7d rows.
func (s *Store) AccountEarningsWindows(accountID string, now time.Time) (contracts.AccountEarningsWindows, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	cutoff24h := now.Add(-24 * time.Hour)
	cutoff7d := now.Add(-7 * 24 * time.Hour)
	var w contracts.AccountEarningsWindows
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

func (s *Store) GetReputations(_ context.Context, providerIDs []string) (map[string]*contracts.ReputationRecord, error) {
	out := make(map[string]*contracts.ReputationRecord, len(providerIDs))
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
