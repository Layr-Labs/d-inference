package registry

import (
	"fmt"
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	maxPrefixCacheStatuses         = 16
	maxPrefixCacheDonationOutcomes = 13
)

var (
	prefixCacheStatusStates  = []string{"ready", "pending", "disabled", "error"}
	prefixCacheStatusReasons = []string{
		"ready",
		"config_disabled",
		"no_loaded_slot",
		"weight_hash_unavailable",
		"runtime_identity_unavailable",
		"unsupported_layout",
		"unsupported_backend",
		"paged_hybrid_unsupported",
		"scan_pending",
		"scan_failed",
		"disk_unavailable",
		"cache_init_failed",
	}
	prefixCacheStatusBackends   = []string{"contiguous", "paged", "unknown"}
	prefixCacheReplayStrategies = []string{"direct", "frozen_full", "none", "unknown"}
	prefixCacheDonationOutcomes = []string{
		"donated",
		"below_effective_token_floor",
		"no_complete_block",
		"lossy_snapshot",
		"incomplete_layer_state",
		"stage_size_exceeded",
		"write_rate_limited",
		"write_queue_full",
		"already_durable",
		"already_queued",
		"cache_closed",
		"disk_unavailable",
		"write_failed",
	}
)

func PrefixCacheStatusStates() []string   { return append([]string(nil), prefixCacheStatusStates...) }
func PrefixCacheStatusReasons() []string  { return append([]string(nil), prefixCacheStatusReasons...) }
func PrefixCacheStatusBackends() []string { return append([]string(nil), prefixCacheStatusBackends...) }
func PrefixCacheReplayStrategies() []string {
	return append([]string(nil), prefixCacheReplayStrategies...)
}
func PrefixCacheDonationOutcomes() []string {
	return append([]string(nil), prefixCacheDonationOutcomes...)
}

func validatePrefixCacheStatuses(
	statuses *[]protocol.PrefixCacheModelStatus,
	models map[string]protocol.ModelInfo,
	catalog map[string]struct{},
) (map[string]protocol.PrefixCacheModelStatus, bool, error) {
	if statuses == nil {
		return nil, false, nil
	}
	if len(*statuses) > maxPrefixCacheStatuses {
		return nil, false, fmt.Errorf(
			"%w: too many prefix-cache statuses", errInvalidPrefixCacheCapability)
	}
	result := make(map[string]protocol.PrefixCacheModelStatus, len(*statuses))
	for _, status := range *statuses {
		if status.ModelID == "" {
			return nil, false, fmt.Errorf(
				"%w: blank prefix-cache status model", errInvalidPrefixCacheCapability)
		}
		if _, ok := models[status.ModelID]; !ok {
			return nil, false, fmt.Errorf(
				"%w: status model %q is not advertised", errInvalidPrefixCacheCapability, status.ModelID)
		}
		if catalog != nil {
			if _, ok := catalog[status.ModelID]; !ok {
				return nil, false, fmt.Errorf(
					"%w: status model %q is not in catalog", errInvalidPrefixCacheCapability, status.ModelID)
			}
		}
		if _, duplicate := result[status.ModelID]; duplicate {
			return nil, false, fmt.Errorf(
				"%w: duplicate status model %q", errInvalidPrefixCacheCapability, status.ModelID)
		}
		if !containsFixed(prefixCacheStatusStates, status.State) ||
			!containsFixed(prefixCacheStatusReasons, status.Reason) ||
			!containsFixed(prefixCacheStatusBackends, status.Backend) ||
			!containsFixed(prefixCacheReplayStrategies, status.ReplayStrategy) ||
			!validPrefixCacheStateReason(status.State, status.Reason) {
			return nil, false, fmt.Errorf(
				"%w: invalid status tuple for %q", errInvalidPrefixCacheCapability, status.ModelID)
		}
		result[status.ModelID] = status
	}
	return result, true, nil
}

func validPrefixCacheStateReason(state, reason string) bool {
	switch state {
	case "ready":
		return reason == "ready"
	case "pending":
		return reason == "scan_pending"
	case "disabled":
		switch reason {
		case "config_disabled", "no_loaded_slot", "weight_hash_unavailable",
			"runtime_identity_unavailable", "unsupported_layout",
			"unsupported_backend", "paged_hybrid_unsupported":
			return true
		}
	case "error":
		switch reason {
		case "scan_failed", "disk_unavailable", "cache_init_failed":
			return true
		}
	}
	return false
}

func validatePrefixCacheDonationOutcomes(
	outcomes *[]protocol.PrefixCacheDonationOutcomeCount,
) (map[string]uint64, error) {
	if outcomes == nil {
		return nil, nil
	}
	if len(*outcomes) > maxPrefixCacheDonationOutcomes {
		return nil, fmt.Errorf(
			"%w: too many prefix-cache donation outcomes", errInvalidPrefixCacheCapability)
	}
	result := make(map[string]uint64, len(*outcomes))
	for _, outcome := range *outcomes {
		if !containsFixed(prefixCacheDonationOutcomes, outcome.Outcome) ||
			outcome.Count == 0 || outcome.Count > math.MaxInt64 {
			return nil, fmt.Errorf(
				"%w: invalid donation outcome %q", errInvalidPrefixCacheCapability, outcome.Outcome)
		}
		if _, duplicate := result[outcome.Outcome]; duplicate {
			return nil, fmt.Errorf(
				"%w: duplicate donation outcome %q", errInvalidPrefixCacheCapability, outcome.Outcome)
		}
		result[outcome.Outcome] = outcome.Count
	}
	return result, nil
}

func containsFixed(values []string, candidate string) bool {
	for _, value := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

// ValidatePrefixCacheRegistration validates all optional cache observability
// snapshots against both the provider inventory and the live catalog. A nil
// catalog preserves development/test behavior.
func (r *Registry) ValidatePrefixCacheRegistration(msg *protocol.RegisterMessage) error {
	if err := ValidatePrefixCacheRegistration(msg); err != nil {
		return err
	}
	models, err := uniqueProviderModels(msg.Models)
	if err != nil {
		return err
	}
	var catalog map[string]struct{}
	if r != nil {
		r.mu.RLock()
		if r.modelCatalog != nil {
			catalog = make(map[string]struct{}, len(r.modelCatalog))
			for modelID := range r.modelCatalog {
				catalog[modelID] = struct{}{}
			}
		}
		r.mu.RUnlock()
	}
	if _, _, err := validatePrefixCacheStatuses(msg.PrefixCacheStatuses, models, catalog); err != nil {
		return err
	}
	_, err = validatePrefixCacheDonationOutcomes(msg.PrefixCacheDonationOutcomes)
	return err
}

// UpdatePrefixCacheTelemetry replaces the optional connection-scoped status
// snapshot and folds monotonic donation-counter deltas into central aggregate
// counters. Omitted fields preserve mixed-version behavior; a present empty
// status array authoritatively clears loaded-model status.
func (r *Registry) UpdatePrefixCacheTelemetry(
	providerID string,
	statuses *[]protocol.PrefixCacheModelStatus,
	outcomes *[]protocol.PrefixCacheDonationOutcomeCount,
) error {
	if r == nil || (statuses == nil && outcomes == nil) {
		return nil
	}
	r.mu.RLock()
	provider := r.providers[providerID]
	var catalog map[string]struct{}
	if r.modelCatalog != nil {
		catalog = make(map[string]struct{}, len(r.modelCatalog))
		for modelID := range r.modelCatalog {
			catalog[modelID] = struct{}{}
		}
	}
	r.mu.RUnlock()
	if provider == nil {
		return fmt.Errorf("%w: provider is not registered", errInvalidPrefixCacheCapability)
	}

	provider.mu.Lock()
	models, err := uniqueProviderModels(provider.Models)
	if err != nil {
		provider.mu.Unlock()
		return err
	}
	validatedStatuses, reported, err := validatePrefixCacheStatuses(statuses, models, catalog)
	if err != nil {
		provider.mu.Unlock()
		return err
	}
	validatedOutcomes, err := validatePrefixCacheDonationOutcomes(outcomes)
	if err != nil {
		provider.mu.Unlock()
		return err
	}
	if reported {
		provider.PrefixCacheStatuses = validatedStatuses
		provider.PrefixCacheStatusReported = true
	}
	deltas := make(map[string]uint64)
	if outcomes != nil {
		nextOutcomes := make(map[string]uint64, len(provider.PrefixCacheDonationOutcomes)+len(validatedOutcomes))
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
		provider.PrefixCacheDonationOutcomes = nextOutcomes
	}
	provider.mu.Unlock()

	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker != nil {
		tracker.recordDonationOutcomes(deltas)
	}
	return nil
}

func (r *Registry) ClearPrefixCacheStatuses(providerID string) {
	if r == nil {
		return
	}
	r.mu.RLock()
	provider := r.providers[providerID]
	r.mu.RUnlock()
	if provider == nil {
		return
	}
	provider.mu.Lock()
	provider.PrefixCacheStatuses = nil
	provider.PrefixCacheStatusReported = true
	provider.mu.Unlock()
}
