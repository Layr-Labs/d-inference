package capacityvalue

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
func CanonicalHeartbeatModelState(
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

	var capacity protocol.BackendCapacity
	CloneBackendCapacityFields(&capacity, reportedCapacity)
	if reportedCapacity.Slots != nil {
		slotLimit := len(reportedCapacity.Slots)
		if slotLimit > len(accepted) {
			slotLimit = len(accepted)
		}
		capacity.Slots = make([]protocol.BackendSlotCapacity, 0, slotLimit)
		seenSlots := make(map[string]struct{}, slotLimit)
		for index := range reportedCapacity.Slots {
			reportedSlot := &reportedCapacity.Slots[index]
			if _, ok := accepted[reportedSlot.Model]; !ok {
				continue
			}
			if _, duplicate := seenSlots[reportedSlot.Model]; duplicate {
				continue
			}
			seenSlots[reportedSlot.Model] = struct{}{}
			capacity.Slots = append(capacity.Slots, protocol.BackendSlotCapacity{})
			CloneBackendSlot(&capacity.Slots[len(capacity.Slots)-1], reportedSlot)
		}
	}

	return canonicalWarm, canonicalActive, &capacity
}

// CloneBackendCapacityFields detaches the non-slot fields shared by heartbeat
// ingestion and public snapshots. Each caller fills Slots with its own filtered
// or complete copy, preserving nil versus present-empty snapshots.
func CloneBackendCapacityFields(capacity, in *protocol.BackendCapacity) {
	*capacity = *in
	capacity.Slots = nil
	if in.WholeMacServiceUsed != nil {
		used := *in.WholeMacServiceUsed
		capacity.WholeMacServiceUsed = &used
	}
	cloneWholeMacServiceReservations(capacity, in)
	if in.FreeForLoadGB != nil {
		free := *in.FreeForLoadGB
		capacity.FreeForLoadGB = &free
	}
	if in.LoadUsableGB != nil {
		usable := *in.LoadUsableGB
		capacity.LoadUsableGB = &usable
	}
	if in.LoadHeadroomGB != nil {
		headroom := *in.LoadHeadroomGB
		capacity.LoadHeadroomGB = &headroom
	}
	if in.MLXCacheReclaimer != nil {
		reclaimer := *in.MLXCacheReclaimer
		capacity.MLXCacheReclaimer = &reclaimer
	}
	if in.PrefixCacheMaintenance != nil {
		maintenance := *in.PrefixCacheMaintenance
		capacity.PrefixCacheMaintenance = &maintenance
	}
	capacity.Telemetry = in.Telemetry.Clone()
}

func CloneBackendSlot(slot, in *protocol.BackendSlotCapacity) {
	*slot = *in
	if in.PerformanceProfile != nil {
		profile := *in.PerformanceProfile
		profile.MTP = in.PerformanceProfile.MTP.Clone()
		slot.PerformanceProfile = &profile
	}
	if slot.KVBackend != nil {
		backend := *slot.KVBackend
		slot.KVBackend = &backend
	}
	if slot.KVBackendFallbackReason != nil {
		reason := *slot.KVBackendFallbackReason
		slot.KVBackendFallbackReason = &reason
	}
	slot.Telemetry = slot.Telemetry.Clone()
	slot.PerformanceMeasurements = slot.PerformanceMeasurements.Clone()
	slot.DeadlineWork = slot.DeadlineWork.Clone()
	slot.DeadlineProfile = slot.DeadlineProfile.Clone()
	slot.PromptWorkIdentity = slot.PromptWorkIdentity.Clone()
	slot.PrefixCache = in.PrefixCache.Clone()
	slot.PagedStorage = in.PagedStorage.Clone()
}
