package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

// Reserve against fresh provider state while holding the original registry and
// provider critical sections, before the controller publishes any commands.
func (c *warmPoolController) reserveActions(actions []modelLoadAction, now time.Time) []modelLoadAction {
	r := c.registry
	r.mu.Lock()
	defer r.mu.Unlock()
	var reserved []modelLoadAction
	for _, action := range actions {
		p := r.providers[action.ProviderID]
		if p == nil {
			continue
		}
		p.mu.Lock()
		if r.providerHasWarmModelLocked(p, action.ModelID, now) {
			p.mu.Unlock()
			continue
		}
		_, reason := r.warmPoolCandidateReasonLocked(p, action.ModelID, now)
		if reason == warmplan.WarmColdEligible {
			key := pendingload.Key{ProviderID: action.ProviderID, ModelID: action.ModelID}
			p.recordDeadlineActivityLocked(now)
			reservation := r.pendingLoads.Reserve(key, now.Add(pendingModelLoadTTL), now)
			action.reservation = pendingModelLoadSendAttempt{
				provider: p, timing: reservation,
			}
			reserved = append(reserved, action)
		}
		p.mu.Unlock()
	}
	return reserved
}
