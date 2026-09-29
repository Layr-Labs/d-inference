package registry

import (
	"slices"
	"time"
)

// OwnedModelRoutingBlockers explains why an online owned provider advertising
// or reporting a loaded model cannot serve even a plain self-route request.
// It returns only coordinator-defined reasons, never provider identifiers,
// hashes, or raw telemetry. This diagnostic does not relax any routing gate.
func (r *Registry) OwnedModelRoutingBlockers(accountID, model string) []string {
	if accountID == "" {
		return nil
	}
	now := time.Now()
	reasons := make(map[string]struct{})
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.AccountID == accountID && p.Status != StatusOffline && p.Status != StatusUntrusted {
			if reason := r.ownedModelRoutingBlockerLocked(p, model, now); reason != "" {
				reasons[reason] = struct{}{}
			}
		}
		p.mu.Unlock()
	}
	result := make([]string, 0, len(reasons))
	for reason := range reasons {
		result = append(result, reason)
	}
	slices.Sort(result)
	return result
}

// Caller holds r.mu and p.mu. Keep the verdict aligned with the base-shape
// checks in OwnedProviderSummary; residency is evidence for diagnostics only.
func (r *Registry) ownedModelRoutingBlockerLocked(p *Provider, model string, now time.Time) string {
	advertised := false
	for _, m := range p.Models {
		if m.ID == model {
			advertised = true
			break
		}
	}
	if !advertised {
		loaded := false
		if p.BackendCapacity != nil {
			for _, slot := range p.BackendCapacity.Slots {
				if slot.Model == model && slotStateModelLoaded(slot.State) {
					loaded = true
					break
				}
			}
		} else {
			loaded = p.CurrentModel == model
		}
		if loaded {
			return "model_not_advertised"
		}
		return ""
	}
	if ok, reason := r.providerLivenessGateReasonLocked(p, TrustNone, true, now); !ok {
		return reason.String()
	}
	if !r.providerServesOwnedRoutableModelLocked(p, model) {
		if !r.providerMeetsModelRequirementsLocked(p, model) {
			return "model_requirements_unsupported"
		}
		return "model_hash_mismatch"
	}
	if providerTemplateRenderBrokenLocked(p, model) {
		return "template_render_failed"
	}
	if !r.providerEligibleForTraitsLocked(p, model, RequestTraits{}) {
		return "provider_version_unsupported"
	}
	return ""
}
