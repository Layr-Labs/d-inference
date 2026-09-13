package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

func clonePrefixCacheCapabilities(
	in map[string]protocol.PrefixCacheV2Capability,
) map[string]protocol.PrefixCacheV2Capability {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]protocol.PrefixCacheV2Capability, len(in))
	for modelID, capability := range in {
		out[modelID] = capability
	}
	return out
}

func clonePrefixCacheStatuses(
	in map[string]protocol.PrefixCacheModelStatus,
) map[string]protocol.PrefixCacheModelStatus {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]protocol.PrefixCacheModelStatus, len(in))
	for modelID, status := range in {
		out[modelID] = status
	}
	return out
}

// UpdatePrefixCacheSnapshot atomically applies the resulting authoritative
// capability and optional observability state from one heartbeat. Strict
// capability errors abort the update. Optional status is sanitized and
// reconciled against the same resulting capability map before either becomes
// visible, so /v1/cache/status cannot observe a transient contradiction.
func (r *Registry) UpdatePrefixCacheSnapshot(
	providerID string,
	replaceCapabilities bool,
	version int,
	capabilities []protocol.PrefixCacheV2Capability,
	memoryCapabilities *[]protocol.PrefixCacheV2Capability,
	statuses *[]protocol.PrefixCacheModelStatus,
	outcomes *[]protocol.PrefixCacheDonationOutcomeCount,
) (bool, error) {
	if r == nil {
		return false, nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	provider := r.providers[providerID]
	if provider == nil {
		return false, errInvalidPrefixCacheCapability
	}

	provider.mu.Lock()
	models, err := uniqueProviderModels(provider.Models)
	if err != nil {
		provider.mu.Unlock()
		return false, err
	}

	resultVersion := provider.PrefixCacheProtocol
	resultCapabilities := clonePrefixCacheCapabilities(provider.PrefixCacheV2Models)
	resultMemoryCapabilities := clonePrefixCacheCapabilities(provider.PrefixCacheMemoryModels)
	if replaceCapabilities {
		resultCapabilities, err = validatePrefixCacheCapabilities(
			version, capabilities, models)
		if err != nil {
			provider.mu.Unlock()
			return false, err
		}
		resultVersion = version
	}
	if memoryCapabilities != nil {
		resultMemoryCapabilities, err = validateMemoryPrefixCacheCapabilities(
			resultVersion, *memoryCapabilities, models)
		if err != nil {
			provider.mu.Unlock()
			return false, err
		}
	} else if resultVersion < 2 {
		resultMemoryCapabilities = nil
	}

	resultStatuses := clonePrefixCacheStatuses(provider.PrefixCacheStatuses)
	statusReported := provider.PrefixCacheStatusReported
	if statuses != nil {
		resultStatuses, statusReported = sanitizePrefixCacheStatuses(statuses, models)
	}
	resultStatuses, statusReported = reconcilePrefixCacheStatuses(
		resultVersion, resultCapabilities, resultStatuses, statusReported)
	if statuses != nil {
		if statusReported {
			retainPrefixCacheStatuses(statuses, resultStatuses)
		} else {
			*statuses = nil
		}
	}

	validatedOutcomes := sanitizePrefixCacheDonationOutcomes(outcomes)
	deltas := make(map[string]uint64)
	nextOutcomes := provider.PrefixCacheDonationOutcomes
	if outcomes != nil {
		nextOutcomes = make(
			map[string]uint64,
			len(provider.PrefixCacheDonationOutcomes)+len(validatedOutcomes),
		)
		for outcome, previous := range provider.PrefixCacheDonationOutcomes {
			nextOutcomes[outcome] = previous
		}
		for outcome, current := range validatedOutcomes {
			previous := provider.PrefixCacheDonationOutcomes[outcome]
			if current >= previous {
				deltas[outcome] = current - previous
				nextOutcomes[outcome] = current
			}
		}
	}

	capabilitiesChanged := provider.PrefixCacheProtocol != resultVersion ||
		!equalPrefixCacheCapabilities(provider.PrefixCacheV2Models, resultCapabilities) ||
		!equalPrefixCacheCapabilities(provider.PrefixCacheMemoryModels, resultMemoryCapabilities)
	protocolChanged := provider.PrefixCacheProtocol != resultVersion
	changedModels := changedPrefixCacheModels(provider.PrefixCacheV2Models, resultCapabilities,
		provider.PrefixCacheMemoryModels, resultMemoryCapabilities)
	if capabilitiesChanged {
		provider.PrefixCacheProtocol = resultVersion
		provider.PrefixCacheV2Models = resultCapabilities
		provider.PrefixCacheMemoryModels = resultMemoryCapabilities
		provider.prefixCacheRevision++
	}
	provider.PrefixCacheStatuses = resultStatuses
	provider.PrefixCacheStatusReported = statusReported
	if outcomes != nil {
		provider.PrefixCacheDonationOutcomes = nextOutcomes
	}
	// Keep connection/generation ownership and the provider lock until
	// invalidation completes. A replacement connection or newly prepared
	// receipt must not be erased by a delayed old-heartbeat cleanup.
	tracker := r.cacheRouting
	if capabilitiesChanged && tracker != nil {
		if protocolChanged {
			tracker.invalidateProviderEvidence(providerID, cacheHolderRemovalCapabilityChange, true)
		} else {
			tracker.invalidateProviderModels(providerID, changedModels)
		}
	}
	provider.mu.Unlock()
	if tracker != nil {
		tracker.recordDonationOutcomes(deltas)
	}
	return capabilitiesChanged, nil
}
