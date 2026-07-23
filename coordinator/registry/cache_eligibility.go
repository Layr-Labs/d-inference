package registry

import (
	"fmt"
	"math"
	"slices"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	maxPrefixCacheStatuses = 16
	// The aggregate vocabulary remains the 13 known outcomes below. The raw
	// wire cap leaves 19 slots for future-version outcomes while bounding all
	// duplicate/filter work to a small fixed array.
	maxPrefixCacheDonationOutcomeEntries = 32
)

var (
	prefixCacheStatusStates  = []string{"ready", "pending", "disabled", "error"}
	prefixCacheStatusReasons = []string{
		"ready",
		"config_disabled",
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
	prefixCacheReplayStrategies = []string{
		"direct", "frozen_full", "tail_replay", "none", "unknown",
	}
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
		// validPrefixCacheStateReason only accepts (state, reason) tuples drawn
		// from the fixed vocabularies, so no separate membership checks needed.
		if !slices.Contains(prefixCacheStatusBackends, status.Backend) ||
			!slices.Contains(prefixCacheReplayStrategies, status.ReplayStrategy) ||
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
		case "config_disabled", "weight_hash_unavailable",
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

func concreteReadyPrefixCacheStatus(status protocol.PrefixCacheModelStatus) bool {
	if status.State != "ready" || status.Reason != "ready" {
		return false
	}
	if status.Backend != "contiguous" && status.Backend != "paged" {
		return false
	}
	switch status.ReplayStrategy {
	case "direct", "frozen_full", "tail_replay":
		return true
	default:
		return false
	}
}

// reconcilePrefixCacheStatuses cross-validates optional ready status against
// the authoritative routing capability snapshot. Contradictory ready entries
// are dropped. If an advertised v2 capability then lacks exactly one concrete
// ready status, the entire optional snapshot becomes unreported rather than
// weakening or deleting the strict routing capability.
func reconcilePrefixCacheStatuses(
	version int,
	capabilities map[string]protocol.PrefixCacheV2Capability,
	statuses map[string]protocol.PrefixCacheModelStatus,
	reported bool,
) (map[string]protocol.PrefixCacheModelStatus, bool) {
	if !reported {
		return nil, false
	}
	reconciled := make(map[string]protocol.PrefixCacheModelStatus, len(statuses))
	for modelID, status := range statuses {
		if status.State == "ready" {
			if version < 2 || !concreteReadyPrefixCacheStatus(status) {
				continue
			}
			if _, capable := capabilities[modelID]; !capable {
				continue
			}
		}
		reconciled[modelID] = status
	}
	for modelID := range capabilities {
		status, ok := reconciled[modelID]
		if !ok || !concreteReadyPrefixCacheStatus(status) {
			return nil, false
		}
	}
	return reconciled, true
}

func retainPrefixCacheStatuses(
	statuses *[]protocol.PrefixCacheModelStatus,
	reconciled map[string]protocol.PrefixCacheModelStatus,
) {
	if statuses == nil {
		return
	}
	filtered := make([]protocol.PrefixCacheModelStatus, 0, len(reconciled))
	for _, status := range *statuses {
		if _, ok := reconciled[status.ModelID]; ok {
			filtered = append(filtered, status)
		}
	}
	*statuses = filtered
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
	if len(*outcomes) > maxPrefixCacheDonationOutcomeEntries {
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
		if !slices.Contains(prefixCacheDonationOutcomes, outcome.Outcome) ||
			outcome.Count == 0 || outcome.Count > math.MaxInt64 {
			continue
		}
		result[outcome.Outcome] = outcome.Count
		sanitized = append(sanitized, outcome)
	}
	*outcomes = sanitized
	return result
}

// ValidatePrefixCacheRegistration keeps authoritative routing capability
// validation fail-closed, then sanitizes optional observability in place.
// Optional telemetry never closes registration and is scoped only to the
// provider's advertised inventory; owner-local/off-catalog models are valid.
func (r *Registry) ValidatePrefixCacheRegistration(msg *protocol.RegisterMessage) error {
	if msg == nil {
		return fmt.Errorf("%w: missing registration", errInvalidPrefixCacheCapability)
	}
	models, err := uniqueProviderModels(msg.Models)
	if err != nil {
		return err
	}
	capabilities, err := validatePrefixCacheCapabilities(
		msg.PrefixCacheProtocol, msg.PrefixCacheV2Models, models)
	if err != nil {
		return err
	}
	statuses, reported := sanitizePrefixCacheStatuses(msg.PrefixCacheStatuses, models)
	statuses, reported = reconcilePrefixCacheStatuses(
		msg.PrefixCacheProtocol, capabilities, statuses, reported)
	if reported {
		retainPrefixCacheStatuses(msg.PrefixCacheStatuses, statuses)
	} else {
		msg.PrefixCacheStatuses = nil
	}
	sanitizePrefixCacheDonationOutcomes(msg.PrefixCacheDonationOutcomes)
	return nil
}
