package memorypolicy

import (
	"math"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// NativeLoadGB validates an advertised full LOAD estimate. No declaration means
// no change to the catalog/measurement policy, even if estimated_memory_gb was
// reported. MiMo requires the raw catalog size in decimal GB, never minimum RAM
// or an already padded load requirement.
func NativeLoadGB(models []protocol.ModelInfo, model string, catalogSizeGB ...float64) float64 {
	for _, info := range models {
		if info.ID == model && info.ModelType == "mimo_v2" {
			if len(catalogSizeGB) != 1 || !capacityvalue.FinitePositive(catalogSizeGB[0]) ||
				info.SizeBytes <= 0 || info.SSDOffloadedWeightBytes != 0 ||
				info.NativeLoadTransientBytes < 1<<30 ||
				info.NativeLoadTransientBytes > math.MaxInt64-info.SizeBytes ||
				!capacityvalue.FinitePositive(info.EstimatedMemoryGB) {
				return 0 // malformed/legacy declaration: keep catalog x 1.2
			}
			const gib = float64(uint64(1) << 30)
			total := float64(info.SizeBytes+info.NativeLoadTransientBytes) / gib
			if info.EstimatedMemoryGB < total {
				return 0 // an undercut estimate is not a native LOAD declaration
			}
			// Catalog metadata absent from scanner SizeBytes still belongs to
			// the source-size floor. Add the supplement exactly once.
			catalogBytes := catalogSizeGB[0] * 1e9
			if !capacityvalue.FinitePositive(catalogBytes) || catalogBytes >= float64(math.MaxInt64) {
				return 0
			}
			floor := (math.Max(float64(info.SizeBytes), catalogBytes) +
				float64(info.NativeLoadTransientBytes)) / gib
			if !capacityvalue.FinitePositive(floor) || floor*gib >= float64(math.MaxInt64) {
				return 0
			}
			return math.Max(info.EstimatedMemoryGB, floor)
		}
		modelType := strings.ToLower(strings.TrimSpace(info.ModelType))
		if modelType != "qwen4_exp" && modelType != "qwen4_exp_text" {
			continue
		}
		if info.ID != model || info.SizeBytes <= 0 || info.SSDOffloadedWeightBytes <= 0 ||
			info.SSDOffloadedWeightBytes >= info.SizeBytes || !capacityvalue.FinitePositive(info.EstimatedMemoryGB) {
			continue
		}
		resident := info.SizeBytes - info.SSDOffloadedWeightBytes
		minimum := float64(resident) / float64(uint64(1)<<30) * 1.2
		// The native contract includes at least 1 GiB of metadata/host headroom.
		// Overflow, zero and sub-floor declarations preserve legacy accounting.
		if transient := info.NativeLoadTransientBytes; transient >= 1<<30 &&
			transient <= math.MaxInt64-resident {
			minimum = float64(resident+transient) / float64(uint64(1)<<30)
		}
		return math.Max(info.EstimatedMemoryGB, minimum)
	}
	return 0
}
