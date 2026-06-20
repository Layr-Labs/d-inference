package registry

import (
	"sort"
	"time"
)

// ModelPoolMetrics is an admin/metrics snapshot of coordinator-managed public
// model pools. A provider contributes to exactly one AssignedProviders pool;
// active/warm counts are derived from its current backend slots.
type ModelPoolMetrics struct {
	Pool                  string  `json:"pool"`
	AssignedProviders     int     `json:"assigned_providers"`
	WarmProviders         int     `json:"warm_providers"`
	ServingProviders      int     `json:"serving_providers"`
	ActiveRequests        int     `json:"active_requests"`
	TokenBudgetUsed       int64   `json:"token_budget_used"`
	TokenBudgetTotal      int64   `json:"token_budget_total"`
	ObservedDecodeTPS     float64 `json:"observed_decode_tps"`
	ResidentSlotProviders int     `json:"resident_slot_providers"`
}

// ModelPoolAudit captures policy violations DAR-345 wants visible: machines with
// more than one resident public model, and machines co-resident across unrelated
// public pools. Alias desired/previous builds count as the same pool.
type ModelPoolAudit struct {
	ProvidersWithMultipleResidentSlots int `json:"providers_with_multiple_resident_slots"`
	ProvidersWithMultipleActivePools   int `json:"providers_with_multiple_active_pools"`
}

func (r *Registry) SetModelPoolEnforcement(enabled bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.enforceModelPools = enabled
}

func (r *Registry) ModelPoolEnforcementEnabled() bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.enforceModelPools
}

func (r *Registry) ModelPoolKey(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.modelPoolKeyLocked(model)
}

func (r *Registry) modelPoolKeyLocked(model string) string {
	keys := r.modelPoolKeysLocked(model)
	if len(keys) == 0 {
		return ""
	}
	return keys[0]
}

func (r *Registry) modelPoolKeysLocked(model string) []string {
	if model == "" {
		return nil
	}
	if _, ok := r.modelAliases[model]; ok {
		return []string{model}
	}
	var keys []string
	for alias, target := range r.modelAliases {
		if target.Desired == model || target.Previous == model {
			keys = append(keys, alias)
			continue
		}
		for _, retired := range target.Retired {
			if retired == model {
				keys = append(keys, alias)
				break
			}
		}
	}
	if len(keys) > 0 {
		sort.Strings(keys)
		return keys
	}
	return []string{model}
}

func (r *Registry) modelCanSeedPoolLocked(model string) bool {
	if model == "" {
		return false
	}
	if r.modelCatalog == nil {
		return true
	}
	if _, ok := r.modelCatalog[model]; ok {
		return true
	}
	return r.modelPoolKeyLocked(model) != model
}

func (r *Registry) providerCanSeedPoolModelLocked(p *Provider, model string) bool {
	if !r.modelCanSeedPoolLocked(model) {
		return false
	}
	for _, advertised := range p.Models {
		if advertised.ID == model && r.modelAllowedByCatalogLocked(advertised) {
			return true
		}
	}
	return r.modelPoolKeyLocked(model) != model
}

func (r *Registry) assignProviderModelPoolLocked(p *Provider) string {
	if p == nil {
		return ""
	}
	if p.AssignedPool != "" {
		return r.modelPoolKeyLocked(p.AssignedPool)
	}
	seed := r.providerModelPoolSeedLocked(p)
	if seed == "" {
		return ""
	}
	p.AssignedPool = seed
	return r.modelPoolKeyLocked(seed)
}

func (r *Registry) assignProviderModelPool(providerID string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.providers[providerID]
	if !ok {
		return ""
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.assignProviderModelPoolLocked(p)
}

func (r *Registry) providerModelPoolSeedLocked(p *Provider) string {
	if r.providerCanSeedPoolModelLocked(p, p.CurrentModel) {
		return p.CurrentModel
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.State == "running" && r.providerCanSeedPoolModelLocked(p, slot.Model) {
				return slot.Model
			}
		}
		for _, slot := range p.BackendCapacity.Slots {
			if slotStateModelLoaded(slot.State) && r.providerCanSeedPoolModelLocked(p, slot.Model) {
				return slot.Model
			}
		}
	}
	for _, model := range p.WarmModels {
		if r.providerCanSeedPoolModelLocked(p, model) {
			return model
		}
	}
	var commonPools map[string]struct{}
	candidatePools := make(map[string]struct{})
	firstAdvertised := ""
	for _, model := range p.Models {
		if r.modelCanSeedPoolLocked(model.ID) && r.modelAllowedByCatalogLocked(model) {
			keys := r.modelPoolKeysLocked(model.ID)
			if len(keys) == 0 {
				continue
			}
			for _, key := range keys {
				candidatePools[key] = struct{}{}
			}
			if firstAdvertised == "" {
				firstAdvertised = model.ID
				commonPools = make(map[string]struct{}, len(keys))
				for _, key := range keys {
					commonPools[key] = struct{}{}
				}
				continue
			}
			next := make(map[string]struct{})
			for _, key := range keys {
				if _, ok := commonPools[key]; ok {
					next[key] = struct{}{}
				}
			}
			commonPools = next
		}
	}
	if firstAdvertised == "" {
		return ""
	}
	if len(commonPools) == 1 {
		for key := range commonPools {
			if key == firstAdvertised {
				return firstAdvertised
			}
			return key
		}
	}
	if len(commonPools) > 1 {
		return firstAdvertised
	}
	return firstSortedMapKey(candidatePools)
}

func (r *Registry) providerAssignedToModelPoolLocked(p *Provider, model string, allowPrivate bool) bool {
	if !r.enforceModelPools || allowPrivate {
		return true
	}
	if r.assignProviderModelPoolLocked(p) == "" || p.AssignedPool == "" {
		return false
	}
	return r.providerAssignedPoolMatchesModelLocked(p, model)
}

func (r *Registry) providerAssignedOrIdleReassignableToModelPoolLocked(p *Provider, model string, allowPrivate bool) bool {
	if !r.enforceModelPools || allowPrivate {
		return true
	}
	if r.assignProviderModelPoolLocked(p) == "" || p.AssignedPool == "" {
		if !r.providerPoolReassignableLocked(p) {
			return false
		}
		p.AssignedPool = model
		return true
	}
	if r.providerAssignedPoolMatchesModelLocked(p, model) {
		return true
	}
	if !r.providerPoolReassignableLocked(p) {
		return false
	}
	p.AssignedPool = model
	return true
}

func (r *Registry) providerAssignedPoolMatchesModelLocked(p *Provider, model string) bool {
	assigned := r.modelPoolKeysLocked(p.AssignedPool)
	requested := r.modelPoolKeysLocked(model)
	for _, a := range assigned {
		for _, req := range requested {
			if a == req {
				return true
			}
		}
	}
	return false
}

func (r *Registry) providerPoolReassignableLocked(p *Provider) bool {
	if p.pendingCount() != 0 {
		return false
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if backendSlotBusy(slot) || slotStateModelLoaded(slot.State) {
				return false
			}
		}
		return true
	}
	return p.CurrentModel == "" && len(p.WarmModels) == 0
}

func firstSortedMapKey(keys map[string]struct{}) string {
	if len(keys) == 0 {
		return ""
	}
	ordered := make([]string, 0, len(keys))
	for key := range keys {
		ordered = append(ordered, key)
	}
	sort.Strings(ordered)
	return ordered[0]
}

func poolKeysOverlap(a, b []string) bool {
	if len(a) == 0 || len(b) == 0 {
		return false
	}
	seen := make(map[string]struct{}, len(a))
	for _, key := range a {
		seen[key] = struct{}{}
	}
	for _, key := range b {
		if _, ok := seen[key]; ok {
			return true
		}
	}
	return false
}

func (r *Registry) providerPassesRoutingGatesBeforePoolLockedEx(p *Provider, model string, traits RequestTraits, selfRouteOwner bool, now time.Time, ignoreProviderBreaker bool) bool {
	if !r.providerServesCatalogModelLocked(p, model) {
		return false
	}
	if r.dispatchLoadCooldownActiveLocked(p.ID, model, now) {
		return false
	}
	if r.inferenceErrorCooldownActiveLocked(p.ID, model, traits.CooldownShape(), now) {
		return false
	}
	if !ignoreProviderBreaker && r.providerBreakerOpenLocked(p.ID, now) {
		return false
	}
	if p.Status == StatusOffline || p.Status == StatusUntrusted {
		return false
	}
	if p.PrivateOnly && !selfRouteOwner {
		return false
	}
	minTrust := r.MinTrustLevel
	if selfRouteOwner {
		minTrust = TrustNone
	}
	if trustRank(p.TrustLevel) < trustRank(minTrust) {
		return false
	}
	if !p.RuntimeVerified {
		return false
	}
	if !r.providerSupportsPrivateTextLocked(p) {
		return false
	}
	if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		return false
	}
	return r.providerEligibleForTraitsLocked(p, model, traits)
}

func (r *Registry) providerRejectedByModelPoolLocked(p *Provider, model string, traits RequestTraits, now time.Time, ignoreProviderBreaker bool) bool {
	if !r.enforceModelPools {
		return false
	}
	if !r.providerPassesRoutingGatesBeforePoolLockedEx(p, model, traits, false, now, ignoreProviderBreaker) {
		return false
	}
	if p.SystemMetrics.ThermalState == "critical" {
		return false
	}
	return !r.providerAssignedToModelPoolLocked(p, model, false)
}

func (r *Registry) PoolRejectedProviderCount(model string, traits RequestTraits, requiresVision bool, allowedSerials ...string) int {
	allowedSet := make(map[string]struct{}, len(allowedSerials))
	for _, serial := range allowedSerials {
		allowedSet[serial] = struct{}{}
	}
	now := time.Now()
	count := 0
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		if len(allowedSet) > 0 && !providerMatchesAllowedSerial(p, allowedSet) {
			continue
		}
		p.mu.Lock()
		poolRejected := r.providerRejectedByModelPoolLocked(p, model, traits, now, true)
		if poolRejected && requiresVision && !r.providerServesVisionModelLocked(p, model) {
			poolRejected = false
		}
		p.mu.Unlock()
		if poolRejected {
			count++
		}
	}
	return count
}

func (r *Registry) ModelPoolMetricsSnapshot() ([]ModelPoolMetrics, ModelPoolAudit) {
	now := time.Now()
	pools := make(map[string]*ModelPoolMetrics)
	audit := ModelPoolAudit{}
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if !r.publiclyRoutableLocked(p, now) {
			p.mu.Unlock()
			continue
		}
		assigned := r.assignProviderModelPoolLocked(p)
		if assigned == "" {
			p.mu.Unlock()
			continue
		}
		pool := pools[assigned]
		if pool == nil {
			pool = &ModelPoolMetrics{Pool: assigned}
			pools[assigned] = pool
		}
		pool.AssignedProviders++
		residentPools := make(map[string]struct{})
		residentSlots := 0
		providerActiveRequests := 0
		assignedWarm := false
		assignedServing := false
		if p.BackendCapacity != nil {
			used, total := providerTokenBudget(p.BackendCapacity.Slots)
			pool.TokenBudgetUsed += used
			pool.TokenBudgetTotal += total
			for _, slot := range p.BackendCapacity.Slots {
				if !slotStateModelLoaded(slot.State) {
					continue
				}
				residentSlots++
				poolKey := r.modelPoolKeyLocked(slot.Model)
				residentPools[poolKey] = struct{}{}
				if poolKey == assigned {
					assignedWarm = true
					if slot.State == "running" {
						assignedServing = true
					}
					providerActiveRequests += slot.NumRunning + slot.NumWaiting
					if slot.ObservedDecodeTPS > 0 {
						pool.ObservedDecodeTPS += slot.ObservedDecodeTPS
					}
				}
			}
		} else {
			for _, model := range p.WarmModels {
				residentSlots++
				poolKey := r.modelPoolKeyLocked(model)
				residentPools[poolKey] = struct{}{}
				if poolKey == assigned {
					assignedWarm = true
				}
			}
			if r.modelPoolKeyLocked(p.CurrentModel) == assigned {
				providerActiveRequests = p.pendingCountForModelLocked(p.CurrentModel)
				assignedServing = providerActiveRequests > 0
			}
		}
		if assignedWarm {
			pool.WarmProviders++
		}
		if assignedServing {
			pool.ServingProviders++
		}
		if residentSlots > 0 {
			pool.ResidentSlotProviders++
		}
		if residentSlots > 1 {
			audit.ProvidersWithMultipleResidentSlots++
		}
		if len(residentPools) > 1 {
			audit.ProvidersWithMultipleActivePools++
		}
		if providerActiveRequests > 0 {
			pool.ActiveRequests += providerActiveRequests
		}
		p.mu.Unlock()
	}
	result := make([]ModelPoolMetrics, 0, len(pools))
	for _, pool := range pools {
		result = append(result, *pool)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Pool < result[j].Pool })
	return result, audit
}
