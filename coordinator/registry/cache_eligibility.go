package registry

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

var prefixCacheStatusStates = cachepolicy.States()
var prefixCacheStatusReasons = cachepolicy.Reasons()
var prefixCacheStatusBackends = cachepolicy.Backends()
var prefixCacheReplayStrategies = cachepolicy.ReplayStrategies()

func PrefixCacheStatusStates() []string {
	return cachepolicy.States()
}
func PrefixCacheStatusReasons() []string {
	return cachepolicy.Reasons()
}
func PrefixCacheStatusBackends() []string {
	return cachepolicy.Backends()
}
func PrefixCacheReplayStrategies() []string {
	return cachepolicy.ReplayStrategies()
}
func PrefixCacheDonationOutcomes() []string {
	return cachepolicy.DonationOutcomes()
}
func sanitizePrefixCacheStatuses(statuses *[]protocol.PrefixCacheModelStatus, models map[string]protocol.ModelInfo) (map[string]protocol.PrefixCacheModelStatus, bool) {
	return cachepolicy.SanitizeStatuses(statuses, models)
}
func reconcilePrefixCacheStatuses(
	version int, capabilities map[string]protocol.PrefixCacheV2Capability, statuses map[string]protocol.PrefixCacheModelStatus, reported bool) (map[string]protocol.PrefixCacheModelStatus, bool) {
	return cachepolicy.ReconcileStatuses(version, capabilities, statuses, reported)
}
func retainPrefixCacheStatuses(statuses *[]protocol.PrefixCacheModelStatus, reconciled map[string]protocol.PrefixCacheModelStatus) {
	cachepolicy.RetainStatuses(statuses, reconciled)
}
func sanitizePrefixCacheDonationOutcomes(outcomes *[]protocol.PrefixCacheDonationOutcomeCount) map[string]uint64 {
	return cachepolicy.SanitizeDonationOutcomes(outcomes)
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
	if _, err := validateMemoryPrefixCacheCapabilities(
		msg.PrefixCacheProtocol, msg.PrefixCacheMemoryModels, models); err != nil {
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
	_, err := r.UpdatePrefixCacheSnapshot(
		providerID,
		false,
		0,
		nil,
		nil,
		statuses,
		outcomes,
	)
	return err
}
