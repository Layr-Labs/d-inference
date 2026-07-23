package registry

import (
	"fmt"
	"math"
	"strings"

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

// sanitizePrefixCacheStatuses projects optional provider observability into the
// fixed vocabulary this coordinator understands. Telemetry is never an
// admission policy:
//   - nil preserves old-provider omission;
//   - oversized arrays, duplicate model IDs, or blank/non-canonical model IDs
//     drop the whole snapshot to an authoritative empty set;
//   - unknown future enums, invalid tuples, and models absent from this
//     provider's own advertised inventory drop only that entry.
//
// The length check runs before iteration, and accepted arrays are capped at 16,
// so hostile optional telemetry cannot create unbounded work.
func sanitizePrefixCacheStatuses(
	statuses *[]protocol.PrefixCacheModelStatus,
	models map[string]protocol.ModelInfo,
) (map[string]protocol.PrefixCacheModelStatus, bool) {
	if statuses == nil {
		return nil, false
	}
	if len(*statuses) > maxPrefixCacheStatuses {
		*statuses = []protocol.PrefixCacheModelStatus{}
		return map[string]protocol.PrefixCacheModelStatus{}, true
	}

	seen := make(map[string]struct{}, len(*statuses))
	for _, status := range *statuses {
		if status.ModelID == "" || strings.TrimSpace(status.ModelID) != status.ModelID {
			*statuses = []protocol.PrefixCacheModelStatus{}
			return map[string]protocol.PrefixCacheModelStatus{}, true
		}
		if _, duplicate := seen[status.ModelID]; duplicate {
			*statuses = []protocol.PrefixCacheModelStatus{}
			return map[string]protocol.PrefixCacheModelStatus{}, true
		}
		seen[status.ModelID] = struct{}{}
	}

	result := make(map[string]protocol.PrefixCacheModelStatus, len(*statuses))
	sanitized := make([]protocol.PrefixCacheModelStatus, 0, len(*statuses))
	for _, status := range *statuses {
		if _, ok := models[status.ModelID]; !ok {
			continue
		}
		if !containsFixed(prefixCacheStatusStates, status.State) ||
			!containsFixed(prefixCacheStatusReasons, status.Reason) ||
			!containsFixed(prefixCacheStatusBackends, status.Backend) ||
			!containsFixed(prefixCacheReplayStrategies, status.ReplayStrategy) ||
			!validPrefixCacheStateReason(status.State, status.Reason) {
			continue
		}
		result[status.ModelID] = status
		sanitized = append(sanitized, status)
	}
	*statuses = sanitized
	return result, true
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

// sanitizePrefixCacheDonationOutcomes applies the same non-fatal policy to
// cumulative donation counters. Oversized or duplicate snapshots are ignored
// wholesale; unknown future outcomes and invalid counts are dropped entry-wise.
// On heartbeat, an empty sanitized map preserves the provider's prior monotonic
// baseline, so malformed optional counters cannot manufacture a reset delta.
func sanitizePrefixCacheDonationOutcomes(
	outcomes *[]protocol.PrefixCacheDonationOutcomeCount,
) map[string]uint64 {
	if outcomes == nil {
		return nil
	}
	if len(*outcomes) > maxPrefixCacheDonationOutcomes {
		*outcomes = []protocol.PrefixCacheDonationOutcomeCount{}
		return map[string]uint64{}
	}

	seen := make(map[string]struct{}, len(*outcomes))
	for _, outcome := range *outcomes {
		if _, duplicate := seen[outcome.Outcome]; duplicate {
			*outcomes = []protocol.PrefixCacheDonationOutcomeCount{}
			return map[string]uint64{}
		}
		seen[outcome.Outcome] = struct{}{}
	}

	result := make(map[string]uint64, len(*outcomes))
	sanitized := make([]protocol.PrefixCacheDonationOutcomeCount, 0, len(*outcomes))
	for _, outcome := range *outcomes {
		if !containsFixed(prefixCacheDonationOutcomes, outcome.Outcome) ||
			outcome.Count == 0 || outcome.Count > math.MaxInt64 {
			continue
		}
		result[outcome.Outcome] = outcome.Count
		sanitized = append(sanitized, outcome)
	}
	*outcomes = sanitized
	return result
}

func containsFixed(values []string, candidate string) bool {
	for _, value := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

// ValidatePrefixCacheRegistration keeps authoritative routing capability
// validation fail-closed, then sanitizes optional observability in place.
// Optional telemetry never closes registration and is scoped only to the
// provider's advertised inventory; owner-local/off-catalog models are valid.
func (r *Registry) ValidatePrefixCacheRegistration(msg *protocol.RegisterMessage) error {
	if err := ValidatePrefixCacheRegistration(msg); err != nil {
		return err
	}
	models, err := uniqueProviderModels(msg.Models)
	if err != nil {
		return err
	}
	sanitizePrefixCacheStatuses(msg.PrefixCacheStatuses, models)
	sanitizePrefixCacheDonationOutcomes(msg.PrefixCacheDonationOutcomes)
	return nil
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
	validatedStatuses, reported := sanitizePrefixCacheStatuses(statuses, models)
	validatedOutcomes := sanitizePrefixCacheDonationOutcomes(outcomes)
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
