package store

import "time"

// GetAccountEarningsWindows returns complete dashboard aggregates without the
// pagination limit used by GetAccountEarnings for history rendering.
func (s *MemoryStore) GetAccountEarningsWindows(
	accountID string,
	cutoff24h, cutoff7d time.Time,
) (ProviderEarningsWindows, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var windows ProviderEarningsWindows
	for i := range s.providerEarnings {
		earning := &s.providerEarnings[i]
		if earning.AccountID != accountID || earning.CreatedAt.Before(cutoff7d) {
			continue
		}

		windows.Last7dMicroUSD += earning.AmountMicroUSD
		if earning.Model != "base_reward" {
			windows.Last7dJobs++
		}
		if earning.CreatedAt.Before(cutoff24h) {
			continue
		}

		windows.Last24hMicroUSD += earning.AmountMicroUSD
		if earning.Model != "base_reward" {
			windows.Last24hJobs++
		}
	}

	return windows, nil
}
