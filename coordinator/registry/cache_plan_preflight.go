package registry

import (
	"strings"

	cacheactivation "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

type cachePlanAuthority struct {
	mode           string
	tracker        *cacheRoutingTracker
	keys           cacheRouteKeys
	activation     *cacheactivation.Gate
	artifacts      cacheArtifactAllowlist
	catalog        CatalogEntry
	catalogPresent bool
}

// Caller holds r.mu. The planning path keeps its original detached key copies;
// diagnostic readers use only presence checks and never retain or hash keys.
func (r *Registry) cachePlanAuthorityLocked(model string, copyKeys bool) cachePlanAuthority {
	catalog, exists := r.modelCatalog[model]
	keys := r.cacheRouteKeys
	if copyKeys {
		keys = cacheRouteKeys{route: append([]byte(nil), keys.route...),
			scope: append([]byte(nil), keys.scope...), activation: append([]byte(nil), keys.activation...)}
	}
	return cachePlanAuthority{mode: r.cacheRoutingMode, tracker: r.cacheRouting, keys: keys,
		activation: r.cacheActivation, artifacts: r.cacheRoutingAllowedArtifacts, catalog: catalog, catalogPresent: exists}
}

func (r *Registry) snapshotCachePlanAuthority(model string, copyKeys bool) cachePlanAuthority {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.cachePlanAuthorityLocked(model, copyKeys)
}

func cachePlanInputIneligible(clientPresent bool, input CachePlanInput) bool {
	return !clientPresent || input.HasMedia || input.Account == "" || input.Model == "" ||
		!validLowerHex256(input.PromptContractID) || !validLowerHex256(input.ModelAggregateSHA256) || len(input.Body) == 0
}

func cachePlanAuthorityRejection(state cachePlanAuthority, input CachePlanInput) CachePlanOutcome {
	if state.mode != CacheRoutingOn || state.tracker == nil || !state.tracker.generation.Active() {
		return CachePlanOff
	}
	aggregate := strings.ToLower(strings.TrimSpace(state.catalog.WeightHash))
	if !state.catalogPresent || len(state.keys.route) == 0 || len(state.keys.activation) == 0 ||
		!validLowerHex256(aggregate) || aggregate != input.ModelAggregateSHA256 {
		return CachePlanIneligible
	}
	if !state.artifacts.Allows(cachepolicy.Artifact{ModelID: input.Model, ModelAggregateSHA256: input.ModelAggregateSHA256, PromptContractID: input.PromptContractID}) ||
		len(state.keys.scope) == 0 {
		return CachePlanIneligible
	}
	return ""
}

// CachePlanRejection classifies only terminal pre-activation refusals. Allowed
// is not lasting authorization: PlanCacheRouteWithResult independently takes
// current authority before its single sampling/QPS mutation. No HMAC, scope,
// demand, metric or sidecar operation occurs here.
func (r *Registry) CachePlanRejection(client *promptcontract.Client, input CachePlanInput) (CachePlanResult, bool) {
	if r == nil || cachePlanInputIneligible(client != nil, input) {
		return CachePlanResult{Outcome: CachePlanIneligible}, true
	}
	if outcome := cachePlanAuthorityRejection(r.snapshotCachePlanAuthority(input.Model, false), input); outcome != "" {
		return CachePlanResult{Outcome: outcome}, true
	}
	return CachePlanResult{}, false
}
