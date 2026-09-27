package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A proof fence quarantines one advertised (provider, model, tier) capability
// after its receipt contradicted the coordinator's sidecar chain. The fence is
// time-bounded: it starts at cacheProofFenceBase, doubles for every
// consecutive mismatch on the same capability, and never exceeds
// cacheProofFenceMax. A fenced receipt is not a new mismatch and never extends
// the window. An accepted proof after the window lifts forgets the strikes, as
// does a capability change or a record that stays idle past the retention.
const (
	cacheProofFenceBase = 60 * time.Second
	cacheProofFenceMax  = 10 * time.Minute
	// Strike memory: a lapsed record is dropped once it has been inactive for
	// this long, so "consecutive" means the next mismatch arrives within the
	// retention of the previous lift with no accepted proof in between.
	cacheProofFenceRetention = cacheProofFenceMax
)

type cacheV2Fence struct {
	capability protocol.PrefixCacheV2Capability
	until      time.Time
	strikes    uint32
	// lapsed marks the expiry as counted so one window never counts twice.
	lapsed bool
}

func (f cacheV2Fence) active(now time.Time) bool {
	return now.Before(f.until)
}

func (f cacheV2Fence) stale(now time.Time) bool {
	return !now.Before(f.until.Add(cacheProofFenceRetention))
}

func cacheProofFenceDuration(strikes uint32) time.Duration {
	duration := cacheProofFenceBase
	for strike := uint32(1); strike < strikes && duration < cacheProofFenceMax; strike++ {
		duration *= 2
	}
	return min(duration, cacheProofFenceMax)
}

// capabilityRejected reports whether the advertised capability is currently
// fenced. It clears the record when the capability changed, never extends a
// window, and drops a lapsed record only once it is past the retention.
func (t *cacheRoutingTracker) capabilityRejected(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
	now time.Time,
) bool {
	key := cacheV2ProviderModelKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	t.mu.Lock()
	defer t.mu.Unlock()
	fence, ok := t.rejectedV2[key]
	if !ok {
		return false
	}
	if fence.capability != capability {
		t.forgetFenceLocked(key, fence, now)
		return false
	}
	if fence.active(now) {
		return true
	}
	t.settleLapsedFenceLocked(key, fence, now)
	return false
}

// rejectCapability starts or escalates the fence for one mismatch. It returns
// true when the capability is fenced afterwards, including a mismatch that
// raced an already active window; that window is left unchanged.
func (t *cacheRoutingTracker) rejectCapability(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
	now time.Time,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.generation.revoked.Load() {
		return false
	}
	key := cacheV2ProviderModelKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	fence, ok := t.rejectedV2[key]
	if ok {
		fence = t.countLapseLocked(fence, now)
	}
	switch {
	case ok && fence.capability == capability && fence.active(now):
		return true
	case ok && fence.capability == capability && !fence.stale(now):
		if fence.strikes < math.MaxUint32 {
			fence.strikes++
		}
	default:
		fence = cacheV2Fence{capability: capability, strikes: 1}
	}
	fence.until = now.Add(cacheProofFenceDuration(fence.strikes))
	fence.lapsed = false
	t.rejectedV2[key] = fence
	t.fencesApplied++
	return true
}

// resetProofStrikesLocked forgets a lapsed fence once the same capability
// proves a receipt again. An active window is left alone: a receipt that
// passed the fence check before the window opened is not evidence it lifted.
func (t *cacheRoutingTracker) resetProofStrikesLocked(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
	now time.Time,
) {
	key := cacheV2ProviderModelKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	fence, ok := t.rejectedV2[key]
	if !ok || fence.capability != capability || fence.active(now) {
		return
	}
	t.forgetFenceLocked(key, fence, now)
}

// countLapseLocked charges a window that lifted by time to fences_expired
// exactly once, whichever path first observes it.
func (t *cacheRoutingTracker) countLapseLocked(fence cacheV2Fence, now time.Time) cacheV2Fence {
	if !fence.lapsed && !fence.active(now) {
		fence.lapsed = true
		t.fencesExpired++
	}
	return fence
}

func (t *cacheRoutingTracker) settleLapsedFenceLocked(
	key cacheV2ProviderModelKey, fence cacheV2Fence, now time.Time,
) {
	if fence.stale(now) {
		t.forgetFenceLocked(key, fence, now)
		return
	}
	t.rejectedV2[key] = t.countLapseLocked(fence, now)
}

// forgetFenceLocked drops a record for any reason (capability change,
// accepted proof, retention, provider disconnect) without losing the count
// of a window that had already lifted.
func (t *cacheRoutingTracker) forgetFenceLocked(
	key cacheV2ProviderModelKey, fence cacheV2Fence, now time.Time,
) {
	t.countLapseLocked(fence, now)
	delete(t.rejectedV2, key)
}

// sweepFencesLocked bounds the fence map: every lapsed window is counted once
// and forgotten after the retention.
func (t *cacheRoutingTracker) sweepFencesLocked(now time.Time) int {
	fenced := 0
	for key, fence := range t.rejectedV2 {
		if fence.active(now) {
			fenced++
			continue
		}
		t.settleLapsedFenceLocked(key, fence, now)
	}
	return fenced
}

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
	if t == nil || providerID == "" || !plan.present() || len(routeKey) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, anchor := range plan.Boundaries {
		for _, tier := range [...]string{"ssd", "memory"} {
			if key := cacheTierBoundaryKey(routeKey, plan, anchor, tier); key != "" {
				t.removeHolderLocked(key, providerID, reason)
			}
		}
	}
}
