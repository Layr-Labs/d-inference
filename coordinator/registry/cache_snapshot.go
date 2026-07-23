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
	statuses *[]protocol.PrefixCacheModelStatus,
	outcomes *[]protocol.PrefixCacheDonationOutcomeCount,
) (bool, error) {
	if r == nil {
		return false, nil
	}
	r.mu.RLock()
	provider := r.providers[providerID]
	r.mu.RUnlock()
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
	if replaceCapabilities {
		resultCapabilities, err = validatePrefixCacheCapabilities(
			version, capabilities, models)
		if err != nil {
			provider.mu.Unlock()
			return false, err
		}
		resultVersion = version
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
		!equalPrefixCacheCapabilities(provider.PrefixCacheV2Models, resultCapabilities)
	removalReason := prefixCacheCapabilityRemovalReason(
		provider.PrefixCacheV2Models, resultCapabilities)
	if capabilitiesChanged {
		provider.PrefixCacheProtocol = resultVersion
		provider.PrefixCacheV2Models = resultCapabilities
		provider.prefixCacheRevision++
	}
	provider.PrefixCacheStatuses = resultStatuses
	provider.PrefixCacheStatusReported = statusReported
	if outcomes != nil {
		provider.PrefixCacheDonationOutcomes = nextOutcomes
	}
	provider.mu.Unlock()

	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if capabilitiesChanged && tracker != nil {
		tracker.disconnect(providerID, removalReason)
	}
	if tracker != nil {
		tracker.recordDonationOutcomes(deltas)
	}
	return capabilitiesChanged, nil
}
