package registry

import (
	"maps"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
) error {
	if r == nil {
		return nil
	}
	r.mu.RLock()
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if provider == nil {
		return errInvalidPrefixCacheCapability
	}

	provider.mu.Lock()
	models, err := uniqueProviderModels(provider.Models)
	if err != nil {
		provider.mu.Unlock()
		return err
	}

	// The stored maps are only read below; every write path assigns a freshly
	// built map (validate/reconcile), so no defensive copies are needed.
	resultVersion := provider.PrefixCacheProtocol
	resultCapabilities := provider.PrefixCacheV2Models
	if replaceCapabilities {
		resultCapabilities, err = validatePrefixCacheCapabilities(
			version, capabilities, models)
		if err != nil {
			provider.mu.Unlock()
			return err
		}
		resultVersion = version
	}

	resultStatuses := provider.PrefixCacheStatuses
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

	// Fold monotonic donation counters: only strictly advancing counters
	// produce deltas; equal counters are no-ops and regressions preserve the
	// prior baseline, so no map rebuild happens on an unchanged heartbeat.
	validatedOutcomes := sanitizePrefixCacheDonationOutcomes(outcomes)
	var deltas map[string]uint64
	for outcome, current := range validatedOutcomes {
		if current <= provider.PrefixCacheDonationOutcomes[outcome] {
			continue
		}
		if deltas == nil {
			deltas = make(map[string]uint64, len(validatedOutcomes))
		}
		deltas[outcome] = current - provider.PrefixCacheDonationOutcomes[outcome]
	}
	if len(deltas) > 0 {
		nextOutcomes := make(
			map[string]uint64,
			len(provider.PrefixCacheDonationOutcomes)+len(deltas),
		)
		maps.Copy(nextOutcomes, provider.PrefixCacheDonationOutcomes)
		for outcome := range deltas {
			nextOutcomes[outcome] = validatedOutcomes[outcome]
		}
		provider.PrefixCacheDonationOutcomes = nextOutcomes
	}

	capabilitiesChanged := provider.PrefixCacheProtocol != resultVersion ||
		!equalPrefixCacheCapabilities(provider.PrefixCacheV2Models, resultCapabilities)
	var removalReason cacheHolderRemovalReason
	if capabilitiesChanged {
		removalReason = prefixCacheCapabilityRemovalReason(
			provider.PrefixCacheV2Models, resultCapabilities)
		provider.PrefixCacheProtocol = resultVersion
		provider.PrefixCacheV2Models = resultCapabilities
		provider.prefixCacheRevision++
	}
	provider.PrefixCacheStatuses = resultStatuses
	provider.PrefixCacheStatusReported = statusReported
	provider.mu.Unlock()

	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker == nil {
		return nil
	}
	if capabilitiesChanged {
		tracker.disconnect(providerID, removalReason)
	}
	tracker.recordDonationOutcomes(deltas)
	return nil
}
