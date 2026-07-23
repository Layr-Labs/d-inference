package registry

import (
	"errors"
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

var errInvalidPrefixCacheCapability = errors.New("invalid prefix-cache capability")

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

func prefixCacheCapabilityRemovalReason(
	previous, current map[string]protocol.PrefixCacheV2Capability,
) cacheHolderRemovalReason {
	if len(previous) == 0 || len(previous) != len(current) {
		return cacheHolderRemovalCapabilityChange
	}
	epochChanged := false
	for modelID, before := range previous {
		after, ok := current[modelID]
		if !ok {
			return cacheHolderRemovalCapabilityChange
		}
		if before.CacheEpoch != after.CacheEpoch {
			epochChanged = true
			before.CacheEpoch = after.CacheEpoch
		}
		if before != after {
			return cacheHolderRemovalCapabilityChange
		}
	}
	if epochChanged {
		return cacheHolderRemovalEpochChange
	}
	return cacheHolderRemovalCapabilityChange
}
