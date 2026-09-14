package routingcost

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func SlotStatePenalty(state string) (float64, bool) {
	switch state {
	case "", "running", "idle":
		return SlotStatePenaltyRunning, true
	case "unknown":
		// Model is available but not loaded. The provider must evict the
		// current model and load this one — typically 15–60 seconds for
		// large models (depends on model size and disk speed). Warm
		// providers are strongly preferred but cold providers are still
		// eligible when no warm alternative exists.
		return SlotStatePenaltyUnknown, true
	case "idle_shutdown":
		return SlotStatePenaltyIdleShutdown, true
	case "reloading", "crashed":
		return math.Inf(1), false
	default:
		return SlotStatePenaltyUnknown, true
	}
}

func SlotStateModelLoaded(state string) bool {
	return state == "running" || state == "idle"
}

func BacklogTokenMs(maxTokensPotential int64, waitingTokens, unaccountedPendingTokens, decodeTPS float64) float64 {
	if decodeTPS <= 0 {
		decodeTPS = 1.0
	}
	totalTokensAhead := float64(maxTokensPotential) + waitingTokens + unaccountedPendingTokens
	if totalTokensAhead < 0 {
		totalTokensAhead = 0
	}
	return totalTokensAhead / decodeTPS * 1000.0
}

func HealthPenaltyMs(m protocol.SystemMetrics, gpuActiveGB, totalMemGB float64) float64 {
	penalty := m.MemoryPressure*memoryPressurePenaltyMs + m.CPUUsage*cpuUsagePenaltyMs
	switch m.ThermalState {
	case "fair":
		penalty += thermalPenaltyFairMs
	case "serious":
		penalty += thermalPenaltySeriousMs
	}
	if totalMemGB > 0 {
		gpuUtil := gpuActiveGB / totalMemGB
		if gpuUtil < 0 {
			gpuUtil = 0
		}
		if gpuUtil > 1 {
			gpuUtil = 1
		}
		penalty += gpuUtil * gpuUtilizationPenaltyMs
	}
	return penalty
}

const (
	SlotStatePenaltyRunning      = 0.0
	SlotStatePenaltyUnknown      = 30_000.0
	SlotStatePenaltyIdleShutdown = 20_000.0
	memoryPressurePenaltyMs      = 4_000.0
	cpuUsagePenaltyMs            = 1_500.0
	gpuUtilizationPenaltyMs      = 5_000.0
	thermalPenaltyFairMs         = 2_000.0
	thermalPenaltySeriousMs      = 8_000.0
)
