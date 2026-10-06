package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

var errInvalidPrefixCacheCapability = cachepolicy.ErrInvalidCapability

func uniqueProviderModels(models []protocol.ModelInfo) (map[string]protocol.ModelInfo, error) {
	return cachepolicy.Models(models)
}
func validatePrefixCacheCapabilities(
	version int, capabilities []protocol.PrefixCacheV2Capability, models map[string]protocol.ModelInfo) (map[string]protocol.PrefixCacheV2Capability, error) {
	return cachepolicy.Capabilities(version, capabilities, models)
}
func validateMemoryPrefixCacheCapabilities(version int, capabilities []protocol.PrefixCacheV2Capability, models map[string]protocol.ModelInfo) (map[string]protocol.PrefixCacheV2Capability, error) {
	return cachepolicy.MemoryCapabilities(version, capabilities, models)
}
func prefixCacheV2CapabilityMap(capabilities []protocol.PrefixCacheV2Capability) map[string]protocol.PrefixCacheV2Capability {
	return cachepolicy.CapabilityMap(capabilities)
}
func validLowerHex256(value string) bool {
	return cachepolicy.LowerHex256(value)
}
func equalPrefixCacheCapabilities(left, right map[string]protocol.PrefixCacheV2Capability) bool {
	return cachepolicy.EqualCapabilities(left, right)
}

// UpdatePrefixCacheCapabilities atomically replaces the live connection
// capability set. Changed models lose their evidence; other models retain it.
// Protocol changes invalidate all connection-scoped evidence.
func (r *Registry) UpdatePrefixCacheCapabilities(
	providerID string,
	version int,
	capabilities []protocol.PrefixCacheV2Capability,
) error {
	_, err := r.UpdatePrefixCacheSnapshot(
		providerID,
		true,
		version,
		capabilities,
		nil,
		nil,
		nil,
	)
	return err
}
