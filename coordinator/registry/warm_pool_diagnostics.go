package registry

import (
	"sort"
	"time"
)

// Warm-pool eligibility diagnostics: per model, would the coordinator send this
// machine a load_model, and if not, why not.
//
// The verdict is not computed here. WarmPoolEligibility calls
// warmPoolCandidateReasonLocked — the predicate plan() uses to pick load
// targets — and translates its warmColdReason into a stable wire string. The
// diagnostic and the warming decision cannot disagree because they run the same
// code; the only thing this file owns is the mapping and the memory figures
// published alongside it.

// WarmPoolBlocker is the closed set of reasons a provider is not a warm-pool
// target for one model. The values are wire strings; renaming one breaks
// clients.
type WarmPoolBlocker string

const (
	// WarmPoolBlockerNone: the provider is an eligible warm target.
	WarmPoolBlockerNone WarmPoolBlocker = ""

	// WarmPoolBlockerAlreadyWarm is reported, not a refusal: the model is
	// loaded here, so there is nothing to warm.
	WarmPoolBlockerAlreadyWarm WarmPoolBlocker = "already_warm"

	// Liveness, trust, privacy.
	WarmPoolBlockerOfflineUntrustedPrivate WarmPoolBlocker = "offline_untrusted_private"
	WarmPoolBlockerStateRestoring          WarmPoolBlocker = "state_restoring"
	WarmPoolBlockerTrustOrRuntime          WarmPoolBlocker = "trust_or_runtime"
	WarmPoolBlockerStaleChallenge          WarmPoolBlocker = "stale_challenge"

	// Transient machine state.
	WarmPoolBlockerPendingLoadOrCooldown WarmPoolBlocker = "pending_load_or_cooldown"
	WarmPoolBlockerNotIdle               WarmPoolBlocker = "not_idle"
	WarmPoolBlockerThermalCritical       WarmPoolBlocker = "thermal_critical"

	// Catalog and routing policy.
	WarmPoolBlockerNotServingCatalog WarmPoolBlocker = "not_serving_catalog"
	WarmPoolBlockerDedicatedExcluded WarmPoolBlocker = "dedicated_excluded"

	// Memory.
	WarmPoolBlockerModelTooLarge WarmPoolBlocker = "model_too_large"
	WarmPoolBlockerNoFreeForLoad WarmPoolBlocker = "no_free_for_load"
)

// warmPoolBlockers maps every warmColdReason onto its wire string. A table
// rather than a cast so an internal rename cannot change the public contract;
// TestWarmPoolBlockerMappingIsClosedOverEveryReason fails when a reason in
// warmColdReasons has no entry.
var warmPoolBlockers = map[warmColdReason]WarmPoolBlocker{
	warmColdEligible:       WarmPoolBlockerNone,
	warmColdOfflineUntrust: WarmPoolBlockerOfflineUntrustedPrivate,
	warmColdStateRestoring: WarmPoolBlockerStateRestoring,
	warmColdPendingLoad:    WarmPoolBlockerPendingLoadOrCooldown,
	warmColdNotIdle:        WarmPoolBlockerNotIdle,
	warmColdThermal:        WarmPoolBlockerThermalCritical,
	warmColdTrust:          WarmPoolBlockerTrustOrRuntime,
	warmColdStaleChallenge: WarmPoolBlockerStaleChallenge,
	warmColdNotServing:     WarmPoolBlockerNotServingCatalog,
	warmColdDedicated:      WarmPoolBlockerDedicatedExcluded,
	warmColdTooLarge:       WarmPoolBlockerModelTooLarge,
	warmColdNoFreeForLoad:  WarmPoolBlockerNoFreeForLoad,
}

// warmPoolBlockerFor translates an internal reason. An unmapped reason is
// returned as its raw label so it never reads as eligible; the closed-set test
// turns that into a CI failure.
func warmPoolBlockerFor(reason warmColdReason) WarmPoolBlocker {
	if b, ok := warmPoolBlockers[reason]; ok {
		return b
	}
	return WarmPoolBlocker(reason)
}

// warmPoolBlockerDescriptions is the operator-facing text for each blocker.
// Fixed strings only; never request or provider data.
var warmPoolBlockerDescriptions = map[WarmPoolBlocker]string{
	WarmPoolBlockerNone:                    "the machine is an eligible warm-pool target for this model",
	WarmPoolBlockerAlreadyWarm:             "the model is already loaded on this machine",
	WarmPoolBlockerOfflineUntrustedPrivate: "the machine is offline, untrusted, or in private-only mode",
	WarmPoolBlockerStateRestoring:          "the coordinator is still restoring this machine's persisted state after a reconnect",
	WarmPoolBlockerTrustOrRuntime:          "the machine's trust level or runtime verification is below what public routing requires",
	WarmPoolBlockerStaleChallenge:          "the machine's last passing attestation challenge is older than the freshness window",
	WarmPoolBlockerPendingLoadOrCooldown:   "a load is already in flight, or a recent load failure put this machine and model on a short cooldown",
	WarmPoolBlockerNotIdle:                 "the machine is serving requests; the coordinator only pre-loads onto a fully idle machine",
	WarmPoolBlockerThermalCritical:         "the machine reported a critical thermal state",
	WarmPoolBlockerNotServingCatalog:       "the machine does not advertise this model, or the model is not in the coordinator's catalog",
	WarmPoolBlockerDedicatedExcluded:       "this model only pre-loads onto machines dedicated to it; this machine also serves other model families",
	WarmPoolBlockerModelTooLarge:           "this model's published memory requirement exceeds this machine's total memory, so it can never be pre-loaded here",
	WarmPoolBlockerNoFreeForLoad:           "the machine's own last heartbeat reported less loadable memory than this model's weights need",
}

// Description returns the operator-facing text for b, or the raw wire string
// for an unknown value.
func (b WarmPoolBlocker) Description() string {
	if d, ok := warmPoolBlockerDescriptions[b]; ok {
		return d
	}
	return string(b)
}

// Permanent reports whether the blocker cannot clear without a hardware or
// catalog change. Only model_too_large qualifies: it compares the catalog's
// published requirement against installed memory. Every other blocker,
// including no_free_for_load (a live heartbeat measurement), can clear on its
// own.
func (b WarmPoolBlocker) Permanent() bool {
	return b == WarmPoolBlockerModelTooLarge
}

// ModelWarmPoolEligibility is the warm-pool verdict for one model on one
// machine.
type ModelWarmPoolEligibility struct {
	ID string `json:"id"`
	// Warm: the model is loaded here (slot state running or idle).
	Warm bool `json:"warm"`
	// Eligible: the planner would pick this machine as a load_model target
	// for this model now. Always false when Warm.
	Eligible bool `json:"eligible"`
	// Blocker is why Eligible is false; empty when eligible. Only the first
	// failing gate is reported, in planner order, so clearing it may reveal
	// another.
	Blocker WarmPoolBlocker `json:"blocker,omitempty"`
	// BlockerDescription is Blocker.Description().
	BlockerDescription string `json:"blocker_description,omitempty"`
	// Permanent is Blocker.Permanent().
	Permanent bool `json:"permanent,omitempty"`
	// RequiredMemoryGB is the total-memory threshold modelFitsHardware applies:
	// the catalog's min_ram_gb, else size_gb x modelMemoryHeadroomFactor, else
	// 0 (gate disabled).
	RequiredMemoryGB float64 `json:"required_memory_gb,omitempty"`
	// WeightsGB is the catalog's on-disk size in decimal GB, unpadded. This is
	// the number shown in the catalog, not the number the load gate compares;
	// see LoadThresholdGiB.
	WeightsGB float64 `json:"weights_gb,omitempty"`
	// LoadThresholdGiB is WeightsGB in the provider's load-gate basis (padded
	// GiB, via coldLoadCatalogGBToMemGiB), i.e. what reportedFreeForLoadAdmits
	// compares against FreeForLoadGB. Zero when WeightsGB is unpublished.
	LoadThresholdGiB float64 `json:"load_threshold_gib,omitempty"`
}

// ProviderWarmPoolEligibility is the per-model warm-pool verdict for one
// machine. Per model because one box can be permanently too small for one
// build, busy for a second and eligible for a third.
type ProviderWarmPoolEligibility struct {
	// TotalMemoryGB is the figure the static fit gate used
	// (warmPoolTotalMemoryGBLocked).
	TotalMemoryGB float64 `json:"total_memory_gb,omitempty"`
	// FreeForLoadGB is the machine's last-reported maximum loadable model
	// weight, in padded GiB (the heartbeat field of the same name). Nil when
	// the provider version does not report it, in which case the
	// no_free_for_load gate is skipped. Compare against LoadThresholdGiB, not
	// WeightsGB.
	FreeForLoadGB *float64 `json:"free_for_load_gb,omitempty"`
	// Models has one row per advertised model, sorted by id.
	Models []ModelWarmPoolEligibility `json:"models,omitempty"`
	// Counts over Models.
	EligibleModels           int `json:"eligible_models"`
	WarmModels               int `json:"warm_models"`
	PermanentlyBlockedModels int `json:"permanently_blocked_models"`
	// ChallengeMaxAgeSeconds is the stale_challenge freshness window.
	ChallengeMaxAgeSeconds int `json:"challenge_max_age_seconds"`
}

// WarmPoolEligibility returns the verdict for a connected provider, or nil when
// providerID is not in the registry. Read-only: no planning pass, no
// load_model. Takes r.mu and p.mu.
func (r *Registry) WarmPoolEligibility(providerID string, now time.Time) *ProviderWarmPoolEligibility {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.providers[providerID]
	if !ok {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.warmPoolEligibilityLocked(p, now)
}

// warmPoolEligibilityLocked builds the verdict. Caller holds r.mu and p.mu.
func (r *Registry) warmPoolEligibilityLocked(p *Provider, now time.Time) *ProviderWarmPoolEligibility {
	out := &ProviderWarmPoolEligibility{
		TotalMemoryGB:          warmPoolTotalMemoryGBLocked(p),
		ChallengeMaxAgeSeconds: int(challengeFreshnessMaxAge.Seconds()),
	}
	if free := backendFreeForLoadGB(p.BackendCapacity); free != nil {
		v := *free
		out.FreeForLoadGB = &v
	}

	seen := make(map[string]struct{}, len(p.Models))
	out.Models = make([]ModelWarmPoolEligibility, 0, len(p.Models))
	for _, m := range p.Models {
		if m.ID == "" {
			continue
		}
		if _, dup := seen[m.ID]; dup {
			continue
		}
		seen[m.ID] = struct{}{}

		row := r.modelWarmPoolRowLocked(p, m.ID, now)
		switch {
		case row.Warm:
			out.WarmModels++
		case row.Eligible:
			out.EligibleModels++
		case row.Permanent:
			out.PermanentlyBlockedModels++
		}
		out.Models = append(out.Models, row)
	}
	sort.Slice(out.Models, func(i, j int) bool { return out.Models[i].ID < out.Models[j].ID })
	return out
}

// modelWarmPoolRowLocked builds one model's row. Warmth is checked first, as
// the controller does — warmPoolCandidateReasonLocked is only defined for cold
// providers. Caller holds r.mu and p.mu.
func (r *Registry) modelWarmPoolRowLocked(p *Provider, model string, now time.Time) ModelWarmPoolEligibility {
	weights := r.catalogSizeGBLocked(model)
	row := ModelWarmPoolEligibility{
		ID:               model,
		RequiredMemoryGB: r.requiredMemoryGBLocked(model),
		WeightsGB:        weights,
		LoadThresholdGiB: loadThresholdGiB(weights),
	}

	if r.providerHasWarmModelLocked(p, model, now) {
		row.Warm = true
		row.Blocker = WarmPoolBlockerAlreadyWarm
		row.BlockerDescription = row.Blocker.Description()
		return row
	}

	_, reason := r.warmPoolCandidateReasonLocked(p, model, now)
	row.Blocker = warmPoolBlockerFor(reason)
	row.Eligible = row.Blocker == WarmPoolBlockerNone
	if !row.Eligible {
		row.BlockerDescription = row.Blocker.Description()
		row.Permanent = row.Blocker.Permanent()
	}
	return row
}

// warmPoolTotalMemoryGBLocked is the total-memory basis for the static fit
// gate: the machine's reported backend total when present, else the registered
// hardware figure. Shared by warmPoolCandidateReasonLocked and the diagnostic
// so the published figure is the one the gate used. Caller holds p.mu.
func warmPoolTotalMemoryGBLocked(p *Provider) float64 {
	if p.BackendCapacity != nil && p.BackendCapacity.TotalMemoryGB > 0 {
		return p.BackendCapacity.TotalMemoryGB
	}
	return float64(p.Hardware.MemoryGB)
}

// loadThresholdGiB converts a catalog decimal-GB size into the padded-GiB figure
// reportedFreeForLoadAdmits compares against free_for_load_gb, using the same
// constant so the published threshold cannot drift from the enforced one.
// Zero in, zero out (the gate is skipped when the size is unpublished).
func loadThresholdGiB(catalogSizeGB float64) float64 {
	if catalogSizeGB <= 0 {
		return 0
	}
	return catalogSizeGB * coldLoadCatalogGBToMemGiB
}

// requiredMemoryGBLocked mirrors modelFitsHardware's precedence: min_ram_gb
// when published, else size_gb x modelMemoryHeadroomFactor, else 0 when the
// gate is disabled. Caller holds r.mu.
func (r *Registry) requiredMemoryGBLocked(model string) float64 {
	if minRAM := r.catalogMinRAMGbLocked(model); minRAM > 0 {
		return float64(minRAM)
	}
	if size := r.catalogSizeGBLocked(model); size > 0 {
		return size * modelMemoryHeadroomFactor
	}
	return 0
}
