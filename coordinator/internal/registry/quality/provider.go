package quality

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func ChipClass(hw protocol.Hardware) string {
	if hw.ChipFamily == "" {
		return hw.ChipName
	}
	return hw.ChipFamily + "|" + hw.ChipTier
}

// DecodeFallback uses the registration benchmark before the conservative
// hardware proxy. A silent provider's 1.0 sentinel is not a transfer bound.
func DecodeFallback(benchmark float64, hardware protocol.Hardware) float64 {
	if benchmark > 0 {
		return benchmark
	}
	if bandwidth := float64(hardware.MemoryBandwidthGBs); bandwidth > 0 {
		return math.Sqrt(bandwidth)
	}
	return 1
}

// ConcurrencyLimit preserves token-budget safety valves and the legacy
// hardware fallback. A positive operator limit for the model binds first.
func ConcurrencyLimit(capacity *protocol.BackendCapacity, hardware protocol.Hardware, model string, legacyLimit int) int {
	if capacity != nil {
		for _, slot := range capacity.Slots {
			if slot.Model == model && slot.MaxConcurrency > 0 {
				return slot.MaxConcurrency
			}
		}
	}
	return ProviderConcurrencyLimit(capacity, hardware, legacyLimit)
}

func ProviderConcurrencyLimit(capacity *protocol.BackendCapacity, hardware protocol.Hardware, legacyLimit int) int {
	if capacity == nil {
		return legacyLimit
	}
	for _, slot := range capacity.Slots {
		if slot.ActiveTokenBudgetMax > 0 {
			return 24
		}
	}
	memory := capacity.TotalMemoryGB
	if memory <= 0 {
		memory = float64(hardware.MemoryGB)
	}
	switch {
	case memory <= 24:
		return 2
	case memory <= 48:
		return 4
	case memory <= 96:
		return 6
	case memory <= 128:
		return 8
	default:
		return 12
	}
}

// SoloSampleEligible gates on all co-resident running and waiting work. The
// ingest caller separately requires actual running decode in the sampled slot.
func SoloSampleEligible(capacity *protocol.BackendCapacity) bool {
	if capacity == nil {
		return false
	}
	load := 0
	for _, slot := range capacity.Slots {
		if n := slot.NumRunning + slot.NumWaiting; n > 0 {
			load += n
		}
		if load > 1 {
			return false
		}
	}
	return true
}
