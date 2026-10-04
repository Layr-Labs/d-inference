package registry

import (
	"cmp"
	"slices"
	"time"
)

// AutopilotInventoryReport counts last-reported saved approvals, not verified
// disk inventory, resident models, or routing eligibility. Providers are live
// registry connections, not distinct machines or accounts.
type AutopilotInventoryReport struct {
	GeneratedAt            time.Time                        `json:"generated_at"`
	StaleAfterSeconds      int                              `json:"stale_after_seconds"`
	EnrolledProviders      int                              `json:"enrolled_providers"`
	ParticipatingProviders int                              `json:"participating_providers"`
	PausedProviders        int                              `json:"paused_providers"`
	StaleProviders         int                              `json:"stale_providers"`
	DistinctModels         int                              `json:"distinct_models"`
	TotalApprovals         int                              `json:"total_approvals"`
	ModelsPerProvider      []AutopilotInventoryDistribution `json:"models_per_provider"`
	Models                 []AutopilotInventoryModel        `json:"models"`
}

type AutopilotInventoryDistribution struct {
	ModelCount    int `json:"model_count"`
	ProviderCount int `json:"provider_count"`
}

type AutopilotInventoryModel struct {
	ModelID                string `json:"model_id"`
	ApprovedProviders      int    `json:"approved_providers"`
	ParticipatingProviders int    `json:"participating_providers"`
	PausedProviders        int    `json:"paused_providers"`
	StaleProviders         int    `json:"stale_providers"`
}

// AutopilotInventory snapshots consent under the same lock order as the planner,
// without invoking it. Participation means unpaused consent, not an active lease;
// staleness is an overlapping subset and never discards a saved approval.
func (r *Registry) AutopilotInventory() AutopilotInventoryReport {
	report := AutopilotInventoryReport{
		GeneratedAt:       time.Now().UTC(),
		StaleAfterSeconds: int(DefaultProviderHeartbeatTimeout / time.Second),
		ModelsPerProvider: []AutopilotInventoryDistribution{},
		Models:            []AutopilotInventoryModel{},
	}
	models := map[string]AutopilotInventoryModel{}
	distribution := map[int]int{}
	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.PrivateOnly || !providerAutopilotConsentedLocked(p) {
			p.mu.Unlock()
			continue
		}
		paused := p.ModelAutopilot.Paused
		// Rejected capacity sequences refresh connection liveness but cannot
		// refresh the accepted selection snapshot. Registration alone is stale.
		stale := p.CapacityAcceptedAt.IsZero() || report.GeneratedAt.Sub(p.CapacityAcceptedAt) > DefaultProviderHeartbeatTimeout
		report.EnrolledProviders++
		if paused {
			report.PausedProviders++
		} else {
			report.ParticipatingProviders++
		}
		if stale {
			report.StaleProviders++
		}
		seen := make(map[string]struct{}, len(p.ModelAutopilot.SelectedModels))
		for _, id := range p.ModelAutopilot.SelectedModels {
			if _, ok := seen[id]; ok {
				continue
			}
			seen[id] = struct{}{}
			model := models[id]
			model.ModelID = id
			model.ApprovedProviders++
			if paused {
				model.PausedProviders++
			} else {
				model.ParticipatingProviders++
			}
			if stale {
				model.StaleProviders++
			}
			models[id] = model
		}
		distribution[len(seen)]++
		report.TotalApprovals += len(seen)
		p.mu.Unlock()
	}
	r.mu.RUnlock()
	for count, providers := range distribution {
		report.ModelsPerProvider = append(report.ModelsPerProvider, AutopilotInventoryDistribution{ModelCount: count, ProviderCount: providers})
	}
	for _, model := range models {
		report.Models = append(report.Models, model)
	}
	report.DistinctModels = len(report.Models)
	slices.SortFunc(report.ModelsPerProvider, func(a, b AutopilotInventoryDistribution) int { return cmp.Compare(a.ModelCount, b.ModelCount) })
	slices.SortFunc(report.Models, func(a, b AutopilotInventoryModel) int { return cmp.Compare(a.ModelID, b.ModelID) })
	return report
}
