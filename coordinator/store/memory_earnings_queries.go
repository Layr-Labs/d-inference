package store

import (
	"sort"
	"time"
)

func (s *MemoryStore) GetAccountEarningsPage(
	accountID string,
	limit int,
	before *ProviderEarningsCursor,
) (ProviderEarningsPage, error) {
	if limit <= 0 {
		return ProviderEarningsPage{Earnings: []ProviderEarning{}}, nil
	}

	s.mu.RLock()
	matches := make([]ProviderEarning, 0)
	for i := range s.providerEarnings {
		earning := s.providerEarnings[i]
		if earning.AccountID != accountID || !earningPrecedesCursor(earning, before) {
			continue
		}
		matches = append(matches, earning)
	}
	s.mu.RUnlock()

	sort.Slice(matches, func(i, j int) bool {
		if matches[i].CreatedAt.Equal(matches[j].CreatedAt) {
			return matches[i].ID > matches[j].ID
		}
		return matches[i].CreatedAt.After(matches[j].CreatedAt)
	})

	page := ProviderEarningsPage{Earnings: matches}
	if len(matches) > limit {
		page.Earnings = matches[:limit]
		last := page.Earnings[len(page.Earnings)-1]
		page.Next = &ProviderEarningsCursor{CreatedAt: last.CreatedAt, ID: last.ID}
	}
	if page.Earnings == nil {
		page.Earnings = []ProviderEarning{}
	}
	return page, nil
}

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

func earningPrecedesCursor(earning ProviderEarning, before *ProviderEarningsCursor) bool {
	if before == nil {
		return true
	}
	if earning.CreatedAt.Equal(before.CreatedAt) {
		return earning.ID < before.ID
	}
	return earning.CreatedAt.Before(before.CreatedAt)
}
