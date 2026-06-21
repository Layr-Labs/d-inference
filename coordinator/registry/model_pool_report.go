package registry

import "time"

// ProviderPoolEntry is one machine's pool assignment for the admin report.
type ProviderPoolEntry struct {
	ProviderID    string   `json:"provider_id"`
	AssignedModel string   `json:"assigned_model"`
	State         string   `json:"state"` // "" (unmanaged) | assigned | draining | loading | failed
	AgeSecs       float64  `json:"age_secs"`
	WarmModels    []string `json:"warm_models"`
}

// ModelPoolReport is the DAR-345 observability snapshot: who is assigned what,
// the placement plan (desired vs current pool sizes + last switch count), and
// the co-residency audit (machines holding >1 warm model — should trend to 0
// once pools are enforced). Powers GET /v1/admin/utilization.
type ModelPoolReport struct {
	GateEnabled         bool                `json:"gate_enabled"`
	PlacementEnabled    bool                `json:"placement_enabled"`
	PlacementEnforce    bool                `json:"placement_enforce"`
	Desired             map[string]int      `json:"desired"`
	Current             map[string]int      `json:"current"`
	LastSwitches        int                 `json:"last_switches"`
	ManagedProviders    int                 `json:"managed_providers"`
	CoResidentProviders int                 `json:"co_resident_providers"`
	Providers           []ProviderPoolEntry `json:"providers"`
}

// ModelPoolReport assembles the current pool-assignment + co-residency view.
func (r *Registry) ModelPoolReport() ModelPoolReport {
	report := ModelPoolReport{
		GateEnabled: r.assignmentGateEnabled.Load(),
		Desired:     map[string]int{},
		Current:     map[string]int{},
	}
	if plan, ok := r.LatestPlacementSnapshot(); ok {
		report.Desired = plan.Desired
		report.Current = plan.Current
		report.LastSwitches = plan.Switches
	}

	now := time.Now()
	r.mu.RLock()
	if r.warmPool != nil {
		report.PlacementEnabled = r.warmPool.config.PlacementEnabled
		report.PlacementEnforce = r.warmPool.config.PlacementEnforce
	}
	report.Providers = make([]ProviderPoolEntry, 0, len(r.providers))
	for id, p := range r.providers {
		p.mu.Lock()
		if p.Status == StatusOffline {
			p.mu.Unlock()
			continue
		}
		entry := ProviderPoolEntry{
			ProviderID:    id,
			AssignedModel: p.AssignedModel,
			State:         p.AssignmentState,
			WarmModels:    append([]string(nil), p.WarmModels...),
		}
		if p.AssignedModel != "" {
			report.ManagedProviders++
			if !p.AssignedAt.IsZero() {
				entry.AgeSecs = now.Sub(p.AssignedAt).Seconds()
			}
		}
		if len(p.WarmModels) > 1 {
			report.CoResidentProviders++
		}
		p.mu.Unlock()
		report.Providers = append(report.Providers, entry)
	}
	r.mu.RUnlock()
	return report
}
