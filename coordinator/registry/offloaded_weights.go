package registry

import (
	"math"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry/admission"
)

func finitePositiveMemory(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}

// Caller holds p.mu. No offload declaration means no change to the existing
// catalog/measurement policy, even though older Swift providers already send
// estimated_memory_gb. The estimate cannot undercut the remaining weight bytes
// plus the native provider's declared, checkpoint-derived loading allowance.
// Missing/invalid declarations retain the existing 1.2 load-transient padding.
// MiMo additionally supports an explicit full-LOAD supplement without SSD
// subtraction. It needs the caller's raw catalog/fit size (decimal GB), never
// minimum machine RAM or an already padded load requirement. Existing Qwen
// behavior and two-argument test callers are unchanged.
func advertisedOffloadedMemoryGBLocked(p *Provider, model string, catalogSizeGB ...float64) float64 {
	for _, info := range p.Models {
		if info.ID == model && info.ModelType == "mimo_v2" {
			if len(catalogSizeGB) != 1 || !finitePositiveMemory(catalogSizeGB[0]) ||
				info.SizeBytes <= 0 || info.SSDOffloadedWeightBytes != 0 ||
				info.NativeLoadTransientBytes < 1<<30 ||
				info.NativeLoadTransientBytes > math.MaxInt64-info.SizeBytes ||
				!finitePositiveMemory(info.EstimatedMemoryGB) {
				return 0 // malformed/legacy declaration: keep catalog×1.2
			}
			const gib = float64(uint64(1) << 30)
			total := float64(info.SizeBytes+info.NativeLoadTransientBytes) / gib
			if info.EstimatedMemoryGB < total {
				return 0 // an undercut estimate is not a native LOAD declaration
			}
			// Catalog size can include metadata absent from scanner SizeBytes.
			// Preserve that source-size floor and add the supplement ONCE; do
			// not pad a validated LOAD quote again or erase catalog qualification.
			catalogBytes := catalogSizeGB[0] * 1e9
			if !finitePositiveMemory(catalogBytes) || catalogBytes >= float64(math.MaxInt64) {
				return 0
			}
			floor := (math.Max(float64(info.SizeBytes), catalogBytes) +
				float64(info.NativeLoadTransientBytes)) / gib
			if !finitePositiveMemory(floor) || floor*gib >= float64(math.MaxInt64) {
				return 0
			}
			return math.Max(info.EstimatedMemoryGB, floor)
		}
		modelType := strings.ToLower(strings.TrimSpace(info.ModelType))
		if modelType != "qwen4_exp" && modelType != "qwen4_exp_text" {
			continue
		}
		if info.ID != model || info.SizeBytes <= 0 || info.SSDOffloadedWeightBytes <= 0 ||
			info.SSDOffloadedWeightBytes >= info.SizeBytes || !finitePositiveMemory(info.EstimatedMemoryGB) {
			continue
		}
		resident := info.SizeBytes - info.SSDOffloadedWeightBytes
		minimum := float64(resident) / float64(uint64(1)<<30) * 1.2
		// The native contract includes at least 1 GiB of metadata/host headroom
		// above its copy envelope. Overflow, zero and sub-floor declarations
		// cannot opt a legacy provider into the smaller accounting path.
		if transient := info.NativeLoadTransientBytes; transient >= 1<<30 &&
			transient <= math.MaxInt64-resident {
			minimum = float64(resident+transient) / float64(uint64(1)<<30)
		}
		return math.Max(info.EstimatedMemoryGB, minimum)
	}
	return 0
}

func reportedFreeForLoadAdmitsWithOffload(catalogSizeGB, offloadedMemoryGB float64, freeForLoadGB *float64) (bool, bool) {
	if freeForLoadGB == nil {
		return false, false
	}
	return admission.ReportedLoadAdmits(catalogSizeGB, offloadedMemoryGB, *freeForLoadGB, true)
}
