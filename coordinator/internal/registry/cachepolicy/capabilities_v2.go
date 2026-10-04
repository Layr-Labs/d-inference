package cachepolicy

import (
	"errors"
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

var ErrInvalidCapability = errors.New("invalid prefix-cache capability")

func Models(models []protocol.ModelInfo) (map[string]protocol.ModelInfo, error) {
	result := make(map[string]protocol.ModelInfo, len(models))
	for _, model := range models {
		id := strings.TrimSpace(model.ID)
		if id == "" || id != model.ID {
			return nil, fmt.Errorf("%w: blank or non-canonical model id", ErrInvalidCapability)
		}
		if _, duplicate := result[id]; duplicate {
			return nil, fmt.Errorf("%w: duplicate model %q", ErrInvalidCapability, id)
		}
		result[id] = model
	}
	return result, nil
}

func Capabilities(
	version int,
	capabilities []protocol.PrefixCacheV2Capability,
	models map[string]protocol.ModelInfo,
) (map[string]protocol.PrefixCacheV2Capability, error) {
	if version < 0 || version > 2 {
		return nil, fmt.Errorf("%w: unsupported protocol %d", ErrInvalidCapability, version)
	}
	if version < 2 {
		if len(capabilities) != 0 {
			return nil, fmt.Errorf("%w: v2 models advertised for protocol %d", ErrInvalidCapability, version)
		}
		return nil, nil
	}
	result := make(map[string]protocol.PrefixCacheV2Capability, len(capabilities))
	for _, capability := range capabilities {
		if err := Capability(capability, models); err != nil {
			return nil, err
		}
		if _, duplicate := result[capability.ModelID]; duplicate {
			return nil, fmt.Errorf(
				"%w: duplicate v2 model %q", ErrInvalidCapability, capability.ModelID)
		}
		result[capability.ModelID] = capability
	}
	return result, nil
}

func MemoryCapabilities(
	version int,
	capabilities []protocol.PrefixCacheV2Capability,
	models map[string]protocol.ModelInfo,
) (map[string]protocol.PrefixCacheV2Capability, error) {
	for _, capability := range capabilities {
		if capability.ReadyBoundaryMode != "" {
			return nil, fmt.Errorf("%w: durable boundary mode on resident capability", ErrInvalidCapability)
		}
	}
	return Capabilities(version, capabilities, models)
}

func Capability(
	capability protocol.PrefixCacheV2Capability,
	models map[string]protocol.ModelInfo,
) error {
	model, exists := models[capability.ModelID]
	if !exists {
		return fmt.Errorf(
			"%w: capability model %q is not registered", ErrInvalidCapability, capability.ModelID)
	}
	if !LowerHex256(capability.ModelAggregateHash) ||
		!strings.EqualFold(strings.TrimSpace(model.WeightHash), capability.ModelAggregateHash) {
		return fmt.Errorf(
			"%w: aggregate hash mismatch for %q", ErrInvalidCapability, capability.ModelID)
	}
	if !LowerHex256(capability.PromptContractID) {
		return fmt.Errorf(
			"%w: invalid prompt contract for %q", ErrInvalidCapability, capability.ModelID)
	}
	if capability.BlockHashVersion != promptcontract.BlockHashVersion ||
		capability.BlockSize != promptcontract.BlockSize {
		return fmt.Errorf(
			"%w: unsupported block contract for %q", ErrInvalidCapability, capability.ModelID)
	}
	if !Epoch(capability.CacheEpoch) {
		return fmt.Errorf(
			"%w: invalid cache epoch for %q", ErrInvalidCapability, capability.ModelID)
	}
	if !capability.Enabled || !capability.Ready {
		return fmt.Errorf(
			"%w: advertised v2 model %q is not enabled and ready", ErrInvalidCapability, capability.ModelID)
	}
	if capability.ReadyBoundaryMode != "" &&
		capability.ReadyBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
		return fmt.Errorf("%w: unsupported ready boundary mode", ErrInvalidCapability)
	}
	return nil
}

func CapabilityMap(
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

func LowerHex256(value string) bool {
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

func Epoch(value string) bool {
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

func EqualCapabilities(
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
