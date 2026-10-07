package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// warmPoolWorkModelsLocked shares the warm fleet's public trust, privacy and
// model gates. Load-fit and idle gates are deliberately absent: a public
// provider's busy engine is exactly the work this signal measures. Incoming
// loaded-slot state is checked by reconciliation, not the prior capacity.
// Caller holds r.mu and p.mu.
func (r *Registry) warmPoolWorkModelsLocked(p *Provider, models []protocol.ModelInfo, status string, now time.Time) map[string]bool {
	if r.warmPool == nil || status == "draining" || providerDrainingLocked(p, now) ||
		!r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now) {
		return nil
	}
	eligible := make(map[string]bool, len(models))
	for _, model := range models {
		if r.providerServesRoutableModelLocked(p, model.ID, false) {
			eligible[model.ID] = true
		}
	}
	return eligible
}

// Routing-policy changes can exclude and restore a provider/model entirely
// between heartbeats. Remove affected baselines at the exclusion itself so a
// later eligible report cannot contribute work from that interval. Unchanged
// eligible models keep their baseline across periodic catalog refreshes.
// Caller holds r.mu; lock ordering stays r.mu -> p.mu.
func (r *Registry) pruneWarmPoolWorkBaselinesLocked() {
	now := time.Now()
	for _, p := range r.providers {
		p.mu.Lock()
		r.pruneWarmPoolWorkBaselineLocked(p, now)
		p.mu.Unlock()
	}
}

// Caller holds r.mu and p.mu. Policy publication can use this within its
// existing provider walk, after installing the new authorization state.
func (r *Registry) pruneWarmPoolWorkBaselineLocked(p *Provider, now time.Time) {
	if !r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now) {
		p.warmWork.Reset()
		return
	}
	if p.warmWork.Count() == 0 {
		return
	}
	eligible := make(map[string]bool, len(p.Models))
	for _, model := range p.Models {
		eligible[model.ID] = r.providerServesRoutableModelLocked(p, model.ID, false)
	}
	p.warmWork.Prune(eligible)
}
