package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
)

// Caller holds p.mu while the directory confirms the complete gate verdict.
func (r *Registry) gateStateReasonLocked(view *gateView, model string, traits RequestTraits, now time.Time, ignoreProviderBreaker, ignoreCapacityCooldown bool) (bool, GateReason) {
	decision := view.g.view.Evaluate(model, traits.CooldownShape(), func() string {
		return stableProviderIdentityLocked(view.p)
	}, now, ignoreProviderBreaker, ignoreCapacityCooldown)
	switch decision.Reason {
	case identitygate.DispatchLoadCooldown:
		return false, GateDispatchLoadCooldown
	case identitygate.InferenceErrorCooldown:
		return false, GateErrorCooldown
	case identitygate.CapacityCooldown:
		return false, GateCapacityCooldown
	case identitygate.ProviderBreaker:
		return false, GateBreaker
	case identitygate.HealthEjection:
		return false, GateEjection
	default:
		return true, GateReasonCount
	}
}
