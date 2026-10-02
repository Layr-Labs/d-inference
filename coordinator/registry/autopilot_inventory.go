package registry

import (
	"slices"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A separate bounded inventory cannot grant ordinary serving permission. The
// original models win duplicate IDs, including their exact weight identity.
func validatedAutopilotInventory(models []protocol.ModelInfo, state *protocol.ModelAutopilotState) []protocol.ModelInfo {
	if !state.Enabled || !state.CachedOnly || len(models) > 256 {
		return nil
	}
	var result []protocol.ModelInfo
	for _, model := range models {
		if model.ID != "" && model.WeightHash != "" && slices.Contains(state.SelectedModels, model.ID) {
			result = append(result, model)
		}
	}
	return result
}

func mergeAutopilotInventory(serving, inventory []protocol.ModelInfo) ([]protocol.ModelInfo, map[string]bool) {
	models := append([]protocol.ModelInfo(nil), serving...)
	seen := make(map[string]bool, len(serving))
	for _, model := range serving {
		seen[model.ID] = true
	}
	only := make(map[string]bool)
	for _, model := range inventory {
		if !seen[model.ID] {
			models = append(models, model)
			only[model.ID], seen[model.ID] = true, true
		}
	}
	return models, only
}

func providerOrdinaryModelAllowedLocked(p *Provider, model string) bool {
	return !p.autopilotOnlyModels[model] || (providerAutopilotControlActiveLocked(p) && providerAutopilotAllowsLocked(p, model))
}

func (r *Registry) providerPassesAutopilotGatesLocked(p *Provider, model protocol.ModelInfo, traits RequestTraits, now time.Time) bool {
	// Project the complete permission set a live lease would expose. Using
	// only the ordinary shadow set would promise dedicated Gemma capacity
	// that disappears as soon as the same mixed inventory becomes live.
	if pattern, dedicated := r.dedicatedPatternForLocked(model.ID); dedicated {
		for _, candidate := range p.Models {
			if r.modelAllowedByCatalogLocked(candidate) && r.providerMeetsModelRequirementsLocked(p, candidate.ID) &&
				(providerSelectedModelLocked(p, candidate.ID) || providerAutopilotAllowsLocked(p, candidate.ID)) &&
				!strings.Contains(strings.ToLower(candidate.ID), pattern) {
				return false
			}
		}
	}
	if !p.autopilotOnlyModels[model.ID] {
		return r.providerPassesRoutingGatesLocked(p, model.ID, traits, false, now)
	}
	if model.WeightHash == "" || !providerAutopilotAllowsLocked(p, model.ID) || !r.modelAllowedByCatalogLocked(model) ||
		!r.providerMeetsModelRequirementsLocked(p, model.ID) || r.providerExcludedByDedicatedRuleLocked(p, model.ID) {
		return false
	}
	ok, _ := r.providerPostCatalogGateReasonLocked(p, model.ID, traits, false, now, false, false)
	return ok
}

// A selected model's declared alias successor is an ordinary artifact update,
// not a grant to load unrelated cached models. Live-only candidates do not
// become permanent selection roots by being resident under a lease.
func providerSelectedModelLocked(p *Provider, id string) bool {
	if id == "" || p.autopilotOnlyModels[id] {
		return false
	}
	for _, model := range p.Models {
		if model.ID == id {
			return true
		}
	}
	return false
}

func (r *Registry) providerCanAcquireDesiredModelLocked(p *Provider, desired, previous string) bool {
	return r.providerCanAcquireCatalogModelLocked(p, desired) ||
		(providerSelectedModelLocked(p, previous) && r.providerCanAcquireCatalogArtifactLocked(p, desired))
}

// ServingModelsLocked copies the effective serving advertisement, excluding
// observation-only metadata. The caller must hold p.Mu() for the snapshot.
// UI and stored serving history must share the routing boundary. Integrity
// verification retains the full inventory: an expired lease can leave an
// unroutable model resident while accepted work and cleanup finish.
func (p *Provider) ServingModelsLocked() []protocol.ModelInfo {
	models := make([]protocol.ModelInfo, 0, len(p.Models))
	for _, model := range p.Models {
		if providerOrdinaryModelAllowedLocked(p, model.ID) {
			models = append(models, model)
		}
	}
	return models
}

// Persist the ordinary operator selection, not a transient live control lease.
func (p *Provider) selectedModelsLocked() []protocol.ModelInfo {
	models := make([]protocol.ModelInfo, 0, len(p.Models))
	for _, model := range p.Models {
		if !p.autopilotOnlyModels[model.ID] {
			models = append(models, model)
		}
	}
	return models
}
