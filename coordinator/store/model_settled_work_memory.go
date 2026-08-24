package store

import (
	"sort"
	"time"
)

// ModelSettledWorkTotals aggregates positive inference settlements in
// [since, until). The explicit upper bound makes repeated 30-day snapshots
// auditable and gives the memory and PostgreSQL implementations identical edge
// semantics.
func (s *MemoryStore) ModelSettledWorkTotals(since, until time.Time) ([]ModelSettledWorkTotal, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	byModel := make(map[string]*ModelSettledWorkTotal)
	for _, earning := range s.providerEarnings {
		if earning.Model == "" || earning.Model == "base_reward" || earning.AmountMicroUSD <= 0 {
			continue
		}
		if earning.CreatedAt.Before(since) || !earning.CreatedAt.Before(until) {
			continue
		}
		total := byModel[earning.Model]
		if total == nil {
			total = &ModelSettledWorkTotal{Model: earning.Model}
			byModel[earning.Model] = total
		}
		total.WorkPayoutMicroUSD += earning.AmountMicroUSD
		total.PromptTokens += int64(earning.PromptTokens)
		total.CompletionTokens += int64(earning.CompletionTokens)
		total.Jobs++
	}

	out := make([]ModelSettledWorkTotal, 0, len(byModel))
	for _, total := range byModel {
		out = append(out, *total)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Model < out[j].Model })
	return out, nil
}
