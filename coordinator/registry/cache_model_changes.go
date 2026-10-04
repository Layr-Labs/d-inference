package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// A provider can serve several independent models. Capability changes for B
// must not erase A's holders, receipt nonces, replay sequence or proof fence.
func changedPrefixCacheModels(beforeSSD, afterSSD, beforeMemory, afterMemory map[string]protocol.PrefixCacheV2Capability) map[string]cacheHolderRemovalReason {
	changes := map[string]cacheHolderRemovalReason{}
	compare := func(before, after map[string]protocol.PrefixCacheV2Capability) {
		ids := map[string]struct{}{}
		for id := range before {
			ids[id] = struct{}{}
		}
		for id := range after {
			ids[id] = struct{}{}
		}
		for id := range ids {
			a, had := before[id]
			b, has := after[id]
			if had == has && a == b {
				continue
			}
			reason := cacheHolderRemovalCapabilityChange
			if had && has && a.CacheEpoch != b.CacheEpoch {
				a.CacheEpoch = b.CacheEpoch
				if a == b {
					reason = cacheHolderRemovalEpochChange
				}
			}
			if previous, ok := changes[id]; !ok || previous != cacheHolderRemovalCapabilityChange {
				changes[id] = reason
			}
		}
	}
	compare(beforeSSD, afterSSD)
	compare(beforeMemory, afterMemory)
	return changes
}

// reconcileFences lifts the proof fence on any of this provider's model/tier
// pairs whose advertised capability was replaced, at the moment the heartbeat
// lands rather than at the next query, so fenced_capabilities never counts a
// dead record. A pair that is merely absent keeps its record: a protocol
// toggle that re-advertises the identical capability must not clear
// quarantine, and an unrelated model's update never touches another model.
func (t *cacheRoutingTracker) reconcileFences(
	providerID string,
	ssd, memory map[string]protocol.PrefixCacheV2Capability,
) {
	if t == nil || providerID == "" {
		return
	}
	now := t.now()
	t.mu.Lock()
	defer t.mu.Unlock()
	t.proofs.Reconcile(providerID, ssd, memory, now)
}
