package e2e

import (
	"fmt"
	"math"
	"testing"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

func TestIntegrationConnectedCacheCorrectnessHTTP(t *testing.T) {
	runConnectedCacheHTTP(t, "DARKBLOOM_CONNECTED_CACHE_CORRECTNESS_INPUT", "DARKBLOOM_CONNECTED_CACHE_CORRECTNESS_OUTPUT", true)
}

func validateConnectedRunScope(in connectedCacheInput, correctnessOnly bool) error {
	if in.CorrectnessOnly != correctnessOnly {
		return fmt.Errorf("input correctness_only must match the explicitly selected fixture")
	}
	if correctnessOnly && len(in.Providers) != 2 {
		return fmt.Errorf("correctness fixture requires two explicitly owned provider targets")
	}
	return nil
}

func connectedHostEntryReady(observation testbed.HostObservation, target testbed.ProviderTarget, correctnessOnly bool) error {
	if !correctnessOnly {
		return observation.EntryReady()
	}
	if len(observation.UnexpectedProcesses) != 0 || len(observation.OwnedProcesses) == 0 {
		return fmt.Errorf("correctness entry requires only owned provider processes")
	}
	if observation.HardwareModel != target.HardwareModel || observation.MemoryBytes != target.MemoryBytes {
		return fmt.Errorf("correctness entry host identity differs")
	}
	if math.IsNaN(observation.GPUTemperature) || math.IsInf(observation.GPUTemperature, 0) || observation.GPUTemperature < 0 || math.IsNaN(observation.Load1) || math.IsInf(observation.Load1, 0) || observation.Load1 < 0 || observation.FreeBytes <= 100*(1<<30) {
		return fmt.Errorf("correctness entry has invalid host telemetry or insufficient disk space")
	}
	return nil
}

func connectedSlotsQuiescent(slots []connectedSlot, expected int, model string) bool {
	if expected == 0 || len(slots) != expected {
		return false
	}
	for _, slot := range slots {
		found := false
		if slot.Capacity != nil {
			for _, capacity := range slot.Capacity.Slots {
				if capacity.Model == model {
					found = true
					if capacity.NumRunning != 0 || capacity.NumWaiting != 0 || capacity.ActiveTokens != 0 {
						return false
					}
				}
			}
		}
		if !found {
			return false
		}
	}
	return true
}
