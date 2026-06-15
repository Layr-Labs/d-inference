package registry

import "strings"

// machineWatts maps a normalized (chip family, tier) pair to a realistic
// maximum sustained wall-socket power draw under a compute-intensive
// (inference) load, in watts.
//
// The outer key is the uppercased family (M1..M5); the inner key is the
// title-cased tier (Base/Pro/Max/Ultra). Figures are grounded in Apple's
// published power-consumption support docs (Mac Studio: support.apple.com/
// en-us/102027, Mac mini: support.apple.com/en-us/103253) and independent
// measured "max load" numbers (Notebookcheck/MacRumors) — NOT the PSU-capacity
// "maximum continuous power" rating, which is much higher than real draw.
var machineWatts = map[string]map[string]float64{
	"M1": {"Base": 40, "Pro": 60, "Max": 115, "Ultra": 215},
	"M2": {"Base": 50, "Pro": 75, "Max": 140, "Ultra": 280},
	"M3": {"Base": 50, "Pro": 75, "Max": 150, "Ultra": 290},
	"M4": {"Base": 65, "Pro": 100, "Max": 170, "Ultra": 300},
	"M5": {"Base": 70, "Pro": 105, "Max": 180, "Ultra": 310},
}

// EstimateMachineWatts returns a realistic estimate of an Apple Silicon Mac's
// maximum sustained wall-socket power draw under a compute-intensive (inference)
// load, in watts. Figures are grounded in Apple's published power-consumption
// support docs (Mac Studio: support.apple.com/en-us/102027, Mac mini:
// support.apple.com/en-us/103253) and independent measured "max load" numbers
// (Notebookcheck/MacRumors), NOT the PSU-capacity "maximum continuous power"
// rating which is much higher. Used for the network-power figure on the public
// stats page and landing page.
func EstimateMachineWatts(chipFamily, chipTier string, gpuCores int) float64 {
	family := strings.ToUpper(strings.TrimSpace(chipFamily))
	tier := normalizeTier(chipTier)

	if tiers, ok := machineWatts[family]; ok {
		if w, ok := tiers[tier]; ok {
			return w
		}
	}

	// Fallback for unknown/older/Intel families or empty family: a GPU-core
	// linear model with a 30W floor.
	if gpuCores <= 0 {
		return 30
	}
	return 30 + 3.5*float64(gpuCores)
}

// normalizeTier maps a raw tier string to one of Base/Pro/Max/Ultra. Empty,
// "base", and any unrecognized value all normalize to Base.
func normalizeTier(chipTier string) string {
	switch strings.ToLower(strings.TrimSpace(chipTier)) {
	case "pro":
		return "Pro"
	case "max":
		return "Max"
	case "ultra":
		return "Ultra"
	default:
		return "Base"
	}
}
