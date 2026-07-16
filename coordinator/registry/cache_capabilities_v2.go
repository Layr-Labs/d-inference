package registry

import (
	"errors"
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

var errInvalidPrefixCacheCapability = errors.New("invalid prefix-cache capability")

// ValidatePrefixCacheRegistration rejects ambiguous model inventories and
// malformed v2 capability sets before a provider is admitted to the registry.
func ValidatePrefixCacheRegistration(msg *protocol.RegisterMessage) error {
	if msg == nil {
		return fmt.Errorf("%w: missing registration", errInvalidPrefixCacheCapability)
	}
	models, err := uniqueProviderModels(msg.Models)
	if err != nil {
		return err
	}
	_, err = validatePrefixCacheCapabilities(
		msg.PrefixCacheProtocol, msg.PrefixCacheV2Models, models)
	return err
}

func uniqueProviderModels(models []protocol.ModelInfo) (map[string]protocol.ModelInfo, error) {
	result := make(map[string]protocol.ModelInfo, len(models))
	for _, model := range models {
		id := strings.TrimSpace(model.ID)
		if id == "" || id != model.ID {
			return nil, fmt.Errorf("%w: blank or non-canonical model id", errInvalidPrefixCacheCapability)
		}
		if _, duplicate := result[id]; duplicate {
			return nil, fmt.Errorf("%w: duplicate model %q", errInvalidPrefixCacheCapability, id)
		}
		result[id] = model
	}
	return result, nil
}

func validatePrefixCacheCapabilities(
	version int,
	capabilities []protocol.PrefixCacheV2Capability,
	models map[string]protocol.ModelInfo,
) (map[string]protocol.PrefixCacheV2Capability, error) {
	if version < 0 || version > 2 {
		return nil, fmt.Errorf("%w: unsupported protocol %d", errInvalidPrefixCacheCapability, version)
	}
	if version < 2 {
		if len(capabilities) != 0 {
			return nil, fmt.Errorf("%w: v2 models advertised for protocol %d", errInvalidPrefixCacheCapability, version)
		}
		return nil, nil
	}
	result := make(map[string]protocol.PrefixCacheV2Capability, len(capabilities))
	for _, capability := range capabilities {
		if err := validatePrefixCacheCapability(capability, models); err != nil {
			return nil, err
		}
		if _, duplicate := result[capability.ModelID]; duplicate {
			return nil, fmt.Errorf(
				"%w: duplicate v2 model %q", errInvalidPrefixCacheCapability, capability.ModelID)
		}
		result[capability.ModelID] = capability
	}
	return result, nil
}

func validatePrefixCacheCapability(
	capability protocol.PrefixCacheV2Capability,
	models map[string]protocol.ModelInfo,
) error {
	model, exists := models[capability.ModelID]
	if !exists {
		return fmt.Errorf(
			"%w: capability model %q is not registered", errInvalidPrefixCacheCapability, capability.ModelID)
	}
	if !validLowerHex256(capability.ModelAggregateHash) ||
		!strings.EqualFold(strings.TrimSpace(model.WeightHash), capability.ModelAggregateHash) {
		return fmt.Errorf(
			"%w: aggregate hash mismatch for %q", errInvalidPrefixCacheCapability, capability.ModelID)
	}
	if !validLowerHex256(capability.PromptContractID) {
		return fmt.Errorf(
			"%w: invalid prompt contract for %q", errInvalidPrefixCacheCapability, capability.ModelID)
	}
	if capability.BlockHashVersion != promptcontract.BlockHashVersion ||
		capability.BlockSize != promptcontract.BlockSize {
		return fmt.Errorf(
			"%w: unsupported block contract for %q", errInvalidPrefixCacheCapability, capability.ModelID)
	}
	if !validCacheEpoch(capability.CacheEpoch) {
		return fmt.Errorf(
			"%w: invalid cache epoch for %q", errInvalidPrefixCacheCapability, capability.ModelID)
	}
	if !capability.Enabled || !capability.Ready {
		return fmt.Errorf(
			"%w: advertised v2 model %q is not enabled and ready", errInvalidPrefixCacheCapability, capability.ModelID)
	}
	return nil
}

func prefixCacheV2CapabilityMap(
	capabilities []protocol.PrefixCacheV2Capability,
) map[string]protocol.PrefixCacheV2Capability {
	if len(capabilities) == 0 {
		return nil
	}
	result := make(map[string]protocol.PrefixCacheV2Capability, len(capabilities))
	for _, capability := range capabilities {
		result[capability.ModelID] = capability
	}
	return result
}

func validLowerHex256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

func validCacheEpoch(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, r := range value {
		switch index {
		case 8, 13, 18, 23:
			if r != '-' {
				return false
			}
		default:
			if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
				return false
			}
		}
	}
	return true
}

func equalPrefixCacheCapabilities(
	left, right map[string]protocol.PrefixCacheV2Capability,
) bool {
	if len(left) != len(right) {
		return false
	}
	for model, capability := range left {
		if right[model] != capability {
			return false
		}
	}
	return true
}

// UpdatePrefixCacheCapabilities atomically replaces the live connection
// capability set. Any change invalidates all connection-scoped cache evidence.
func (r *Registry) UpdatePrefixCacheCapabilities(
	providerID string,
	version int,
	capabilities []protocol.PrefixCacheV2Capability,
) error {
	if r == nil {
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
	validated, err := validatePrefixCacheCapabilities(version, capabilities, models)
	if err != nil {
		provider.mu.Unlock()
		return err
	}
	changed := provider.PrefixCacheProtocol != version ||
		!equalPrefixCacheCapabilities(provider.PrefixCacheV2Models, validated)
	if changed {
		provider.PrefixCacheProtocol = version
		provider.PrefixCacheV2Models = validated
	}
	provider.mu.Unlock()

	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if changed && tracker != nil {
		tracker.disconnect(providerID)
	}
	return nil
}
