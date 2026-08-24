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

	// provider_earnings gained PublicModel after usage already persisted it.
	// Recover legacy settlement attribution only when every matching usage row
	// agrees; conflicting or missing history remains explicitly unattributed.
	publicModelByRequest := make(map[string]string)
	for _, usage := range s.usage {
		if usage.RequestID == "" || usage.PublicModel == "" {
			continue
		}
		if existing, seen := publicModelByRequest[usage.RequestID]; !seen {
			publicModelByRequest[usage.RequestID] = usage.PublicModel
		} else if existing != usage.PublicModel {
			publicModelByRequest[usage.RequestID] = ""
		}
	}

	byPublicModel := make(map[string]*ModelSettledWorkTotal)
	for _, earning := range s.providerEarnings {
		if earning.Model == "" || earning.Model == "base_reward" || earning.AmountMicroUSD <= 0 {
			continue
		}
		if earning.CreatedAt.Before(since) || !earning.CreatedAt.Before(until) {
			continue
		}
		publicModel := earning.PublicModel
		if publicModel == "" && earning.JobID != "" {
			publicModel = publicModelByRequest[earning.JobID]
		}
		total := byPublicModel[publicModel]
		if total == nil {
			total = &ModelSettledWorkTotal{PublicModel: publicModel}
			byPublicModel[publicModel] = total
		}
		total.WorkPayoutMicroUSD += earning.AmountMicroUSD
		total.PromptTokens += int64(earning.PromptTokens)
		total.CompletionTokens += int64(earning.CompletionTokens)
		total.Jobs++
	}

	out := make([]ModelSettledWorkTotal, 0, len(byPublicModel))
	for _, total := range byPublicModel {
		out = append(out, *total)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].PublicModel < out[j].PublicModel })
	return out, nil
}
