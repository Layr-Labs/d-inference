package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type cacheV2Fence = cachetracker.FenceRecord

func (t *cacheRoutingTracker) capabilityRejected(providerID, modelID, tier string, capability protocol.PrefixCacheV2Capability, now time.Time) bool {
	key := cacheV2ProviderModelKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.proofs.Rejected(key, capability, now)
}

func (t *cacheRoutingTracker) rejectCapability(providerID, modelID, tier string, capability protocol.PrefixCacheV2Capability, now time.Time) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.proofs.Reject(providerID, modelID, tier, capability, now)
}

func (t *cacheRoutingTracker) sweepFencesLocked(now time.Time) int { return t.proofs.Sweep(now) }

// invalidateProviderPlan drops one provider's holders at the boundaries the
// mismatched plan named, in both tiers: a chain divergence is a tokenization
// disagreement on that prompt, not a tier property. Sequence watermarks and
// other prompts' holders on the same model are untouched.
func (t *cacheRoutingTracker) invalidateProviderPlan(
	providerID string,
	plan CachePlan,
	routeKey []byte,
	reason cacheHolderRemovalReason,
) {
	if t == nil || providerID == "" || !plan.Present() || len(routeKey) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.core.InvalidateProviderPlan(providerID, plan, routeKey, reason)
}
