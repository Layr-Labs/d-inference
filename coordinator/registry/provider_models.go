package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// MergeProviderModels applies a provider's authoritative models_update to its
// advertised Models in place — used for the message a provider sends after it
// converges on a desired build (background prefetch verified, then hard-swap),
// so a new build becomes routable WITHOUT a reconnect and WITHOUT resetting
// trust/reputation/challenge state. It is authoritative for each alias whose
// desired build appears in the validated update: that alias's previous build is
// dropped if omitted. Seeing a build only as another alias's previous build is
// not enough to drop that other alias's desired build, which keeps aliases that
// share a concrete build independent.
//
// Each model's WeightHash is cross-checked against the catalog's expected hash;
// a mismatch is REJECTED (the build is not made routable) so a bad or buggy
// prefetch/swap can never take traffic. Returns build ids that were merged and
// build ids that were dropped from this provider.
func (r *Registry) MergeProviderModels(providerID string, models []protocol.ModelInfo) (merged, dropped []string) {
	return r.mergeProviderModels(providerID, models, 0, nil)
}

// MergeProviderModelsWithCapabilities is the current-provider models_update
// path. Capability fields are authoritative for the concrete models carried by
// this update; omitted fields preserve legacy-provider behavior.
func (r *Registry) MergeProviderModelsWithCapabilities(
	providerID string,
	models []protocol.ModelInfo,
	toolConstraintProtocol int,
	toolConstraintModels []string,
) (merged, dropped []string) {
	return r.mergeProviderModels(
		providerID,
		models,
		toolConstraintProtocol,
		toolConstraintModels,
	)
}

func (r *Registry) mergeProviderModels(
	providerID string,
	models []protocol.ModelInfo,
	toolConstraintProtocol int,
	toolConstraintModels []string,
) (merged, dropped []string) {
	if len(models) == 0 {
		return nil, nil
	}
	updatedToolConstraintModels := toolConstraintModelSet(
		toolConstraintModels, models)
	r.mu.RLock()
	p, ok := r.providers[providerID]
	// hasCatalog mirrors modelAllowedByCatalogLocked: a nil catalog (dev/test
	// setups) imposes no membership gate; a present catalog makes membership
	// mandatory for merging.
	hasCatalog := r.modelCatalog != nil
	expected := make(map[string]CatalogEntry, len(models))
	for _, m := range models {
		if e, has := r.modelCatalog[m.ID]; has {
			expected[m.ID] = e
		}
	}
	// Snapshot the alias targets under the read lock so the drop set can be
	// computed later (under p.mu) without nesting r.mu — and, crucially, from
	// the builds that actually PASS validation below, not from the raw message.
	aliasTargets := make([]AliasTarget, 0, len(r.modelAliases))
	for _, t := range r.modelAliases {
		if !t.OpenRouterOnly {
			aliasTargets = append(aliasTargets, t)
		}
	}

	r.mu.RUnlock()
	if !ok {
		return nil, nil
	}

	p.mu.Lock()
	// present tracks only builds that passed validation and were merged — the
	// hard-swap drop is derived from THIS set, never from the raw message. A
	// desired build rejected for a bad weight hash therefore does NOT cause its
	// previous sibling to be dropped (which would strand the provider on neither
	// build — the exact failure the hash check exists to prevent).
	present := make(map[string]struct{}, len(models))
	cacheStateInvalidated := make(map[string]struct{})
	for _, m := range models {
		if m.ID == "" {
			continue
		}
		// A build the catalog has never heard of is rejected outright (when a
		// catalog exists). It could never be routed anyway
		// (modelAllowedByCatalogLocked), and merging it would let a provider
		// grow its own p.Models without bound via repeated models_update
		// messages carrying fabricated ids.
		entry, inCatalog := expected[m.ID]
		if hasCatalog && !inCatalog {
			r.logger.Warn("models_update for build not in catalog; rejecting",
				"provider_id", providerID, "model_id", m.ID)
			continue
		}
		required := effectiveRequiredProviderCapabilities(
			m.ID, entry.RequiredProviderCapabilities)
		if !capabilitySetContainsAll(p.RuntimeCapabilities, required) {
			r.logger.Warn("models_update provider capability mismatch; rejecting build",
				"provider_id", providerID, "model_id", m.ID)
			continue
		}
		// When the catalog pins an expected hash, a models_update MUST carry a
		// non-empty MATCHING hash. A missing hash is rejected just like a
		// mismatched one.
		if exp := entry.WeightHash; exp != "" && !strings.EqualFold(m.WeightHash, exp) {
			r.logger.Warn("models_update weight-hash missing or mismatched; rejecting build",
				"provider_id", providerID, "model_id", m.ID, "expected", exp, "got", m.WeightHash)
			continue
		}
		replaced := false
		for i := range p.Models {
			if p.Models[i].ID == m.ID {
				if !strings.EqualFold(p.Models[i].WeightHash, m.WeightHash) {
					delete(p.PrefixCacheStatuses, m.ID)
					delete(p.PrefixCacheV2Models, m.ID)
					delete(p.PrefixCacheMemoryModels, m.ID)
					p.prefixCacheRevision++
					cacheStateInvalidated[m.ID] = struct{}{}
				}
				p.Models[i] = m
				replaced = true
				break
			}
		}
		if !replaced {
			p.Models = append(p.Models, m)
		}
		merged = append(merged, m.ID)
		present[m.ID] = struct{}{}
		if toolConstraintProtocol != 0 {
			p.ToolConstraintProtocol = toolConstraintProtocol
			if _, supported := updatedToolConstraintModels[m.ID]; toolConstraintProtocol == ToolConstraintProtocolV1 && supported {
				if p.ToolConstraintModels == nil {
					p.ToolConstraintModels = make(map[string]struct{})
				}
				p.ToolConstraintModels[m.ID] = struct{}{}
			} else {
				delete(p.ToolConstraintModels, m.ID)
			}
		}
	}
	// Compute the hard-swap drop set: a VALIDATED desired build authorizes
	// dropping only that alias's previous build. This is intentionally
	// directional; if two aliases share a build, updating one alias to that shared
	// desired build must not drop the desired build of another alias where the
	// shared build is merely "previous".
	drop := make(map[string]struct{})
	for _, t := range aliasTargets {
		if t.Desired == "" || t.Previous == "" || t.Desired == t.Previous {
			continue
		}
		if _, desiredPresent := present[t.Desired]; !desiredPresent {
			continue
		}
		if _, previousStillPresent := present[t.Previous]; !previousStillPresent {
			drop[t.Previous] = struct{}{}
		}
	}
	// Apply the hard-swap drop: remove any alias-sibling build the provider no
	// longer advertises.
	if len(drop) > 0 {
		kept := p.Models[:0]
		for _, m := range p.Models {
			if _, gone := drop[m.ID]; gone {
				r.logger.Info("models_update hard-swap: dropping retired build",
					"provider_id", providerID, "model_id", m.ID)
				dropped = append(dropped, m.ID)
				delete(p.ToolConstraintModels, m.ID)
				delete(p.PrefixCacheStatuses, m.ID)
				delete(p.PrefixCacheV2Models, m.ID)
				delete(p.PrefixCacheMemoryModels, m.ID)
				p.prefixCacheRevision++
				cacheStateInvalidated[m.ID] = struct{}{}
				continue
			}
			kept = append(kept, m)
		}
		p.Models = kept
	}
	p.PrefixCacheStatuses, p.PrefixCacheStatusReported =
		reconcilePrefixCacheStatuses(
			p.PrefixCacheProtocol,
			p.PrefixCacheV2Models,
			p.PrefixCacheStatuses,
			p.PrefixCacheStatusReported,
		)
	p.syncModelIndexLocked()
	p.mu.Unlock()
	if len(cacheStateInvalidated) > 0 {
		r.mu.RLock()
		tracker := r.cacheRouting
		r.mu.RUnlock()
		if tracker != nil {
			for modelID := range cacheStateInvalidated {
				tracker.invalidateProviderModel(
					providerID, modelID, cacheHolderRemovalCapabilityChange)
			}
		}
	}
	return merged, dropped
}

// UpdateModelWeightHashes replaces stored per-model weight hashes from a
// verified attestation challenge response. A present empty value deliberately
// clears a registration-time hash that the provider could not re-verify; an
// omitted model remains unchanged because unloaded advertised models are absent
// from the challenge snapshot.
//
// Concurrency: the p.Models slice header is replaced (copy-on-write, never
// mutated in place) under p.mu — NOT under the registry-wide r.mu, which is held
// only as a read lock to look the provider up in the map. p.mu is therefore the
// sole lock guarding p.Models, so every reader that ranges p.Models must hold
// p.mu (see providerModelIDs and the *Locked helpers). Do not rely on r.mu to
// serialize reads against this write: it does not.
func (r *Registry) UpdateModelWeightHashes(providerID string, hashes map[string]string) {
	if len(hashes) == 0 {
		return
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	changed := false
	models := make([]protocol.ModelInfo, len(p.Models))
	copy(models, p.Models)
	for i := range models {
		if h, ok := hashes[models[i].ID]; ok && models[i].WeightHash != h {
			models[i].WeightHash = h
			changed = true
		}
	}
	if changed {
		p.Models = models
		p.syncModelIndexLocked() // ids unchanged; keeps the invariant explicit
	}
}
