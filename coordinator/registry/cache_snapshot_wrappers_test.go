package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Test-only convenience wrappers over UpdatePrefixCacheSnapshot. Production
// heartbeat handling always applies capabilities and telemetry through one
// atomic snapshot call (api/provider.go), so these narrower entry points live
// with the tests that use them.

// UpdatePrefixCacheCapabilities atomically replaces the live connection
// capability set. Any change invalidates all connection-scoped cache evidence.
func (r *Registry) UpdatePrefixCacheCapabilities(
	providerID string,
	version int,
	capabilities []protocol.PrefixCacheV2Capability,
) error {
	return r.UpdatePrefixCacheSnapshot(
		providerID, true, version, capabilities, nil, nil)
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
	return r.UpdatePrefixCacheSnapshot(
		providerID, false, 0, nil, statuses, outcomes)
}
