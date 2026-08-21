package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// canonicalHeartbeatModelState copies the provider-authored heartbeat model
// state while constraining every model identifier to the coordinator-accepted
// inventory for this connection. The returned values are owned by the
// registry; callers may clamp or retain them without mutating the decoded
// message. Duplicate known IDs are collapsed, so retained slice capacity is
// bounded by the accepted inventory rather than attacker-controlled heartbeat
// cardinality.
//
// Nil versus present-but-empty slices are preserved because both
// BackendCapacity and WarmModels use an empty snapshot to clear stale state.
// Unknown ActiveModel values are treated the same as no active model.
func canonicalHeartbeatModelState(
	models []protocol.ModelInfo,
	warmModels []string,
	activeModel *string,
	reportedCapacity *protocol.BackendCapacity,
) (canonicalWarm []string, canonicalActive string, canonicalCapacity *protocol.BackendCapacity) {
	accepted := make(map[string]struct{}, len(models))
	for _, model := range models {
		accepted[model.ID] = struct{}{}
	}

	if warmModels != nil {
		warmLimit := len(warmModels)
		if warmLimit > len(accepted) {
			warmLimit = len(accepted)
		}
		canonicalWarm = make([]string, 0, warmLimit)
		seenWarm := make(map[string]struct{}, warmLimit)
		for _, modelID := range warmModels {
			if _, ok := accepted[modelID]; !ok {
				continue
			}
			if _, duplicate := seenWarm[modelID]; duplicate {
				continue
			}
			seenWarm[modelID] = struct{}{}
			canonicalWarm = append(canonicalWarm, modelID)
		}
	}

	if activeModel != nil {
		if _, ok := accepted[*activeModel]; ok {
			canonicalActive = *activeModel
		}
	}

	if reportedCapacity == nil {
		return canonicalWarm, canonicalActive, nil
	}

	capacity := *reportedCapacity
	if reportedCapacity.FreeForLoadGB != nil {
		freeForLoadGB := *reportedCapacity.FreeForLoadGB
		capacity.FreeForLoadGB = &freeForLoadGB
	}
	capacity.MLXCacheReclaimer = cloneMLXCacheReclaimerTelemetry(
		reportedCapacity.MLXCacheReclaimer)
	if reportedCapacity.Slots != nil {
		slotLimit := len(reportedCapacity.Slots)
		if slotLimit > len(accepted) {
			slotLimit = len(accepted)
		}
		capacity.Slots = make([]protocol.BackendSlotCapacity, 0, slotLimit)
		seenSlots := make(map[string]struct{}, slotLimit)
		for _, reportedSlot := range reportedCapacity.Slots {
			if _, ok := accepted[reportedSlot.Model]; !ok {
				continue
			}
			if _, duplicate := seenSlots[reportedSlot.Model]; duplicate {
				continue
			}
			seenSlots[reportedSlot.Model] = struct{}{}
			slot := reportedSlot
			if reportedSlot.KVBackend != nil {
				kvBackend := *reportedSlot.KVBackend
				slot.KVBackend = &kvBackend
			}
			if reportedSlot.KVBackendFallbackReason != nil {
				fallbackReason := *reportedSlot.KVBackendFallbackReason
				slot.KVBackendFallbackReason = &fallbackReason
			}
			capacity.Slots = append(capacity.Slots, slot)
		}
	}

	return canonicalWarm, canonicalActive, &capacity
}

// BackendCapacitySnapshot returns a detached copy of the last accepted
// heartbeat capacity. Callers outside the registry must use this instead of
// the decoded heartbeat: the registry copy has already dropped model IDs that
// were not part of this connection's coordinator-accepted inventory.
func (p *Provider) BackendCapacitySnapshot() *protocol.BackendCapacity {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.BackendCapacity == nil {
		return nil
	}

	capacity := *p.BackendCapacity
	if p.BackendCapacity.FreeForLoadGB != nil {
		freeForLoadGB := *p.BackendCapacity.FreeForLoadGB
		capacity.FreeForLoadGB = &freeForLoadGB
	}
	capacity.MLXCacheReclaimer = cloneMLXCacheReclaimerTelemetry(
		p.BackendCapacity.MLXCacheReclaimer)
	if p.BackendCapacity.Slots != nil {
		capacity.Slots = make([]protocol.BackendSlotCapacity, len(p.BackendCapacity.Slots))
		for index, retainedSlot := range p.BackendCapacity.Slots {
			slot := retainedSlot
			if retainedSlot.KVBackend != nil {
				kvBackend := *retainedSlot.KVBackend
				slot.KVBackend = &kvBackend
			}
			if retainedSlot.KVBackendFallbackReason != nil {
				fallbackReason := *retainedSlot.KVBackendFallbackReason
				slot.KVBackendFallbackReason = &fallbackReason
			}
			capacity.Slots[index] = slot
		}
	}
	return &capacity
}

func cloneMLXCacheReclaimerTelemetry(
	in *protocol.MLXCacheReclaimerTelemetry,
) *protocol.MLXCacheReclaimerTelemetry {
	if in == nil {
		return nil
	}
	copy := *in
	return &copy
}
