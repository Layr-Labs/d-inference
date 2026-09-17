package registry

import (
	"math"
	"strings"
)

func finitePositiveMemory(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}

// Caller holds p.mu. No offload declaration means no change to the existing
// catalog/measurement policy, even though older Swift providers already send
// estimated_memory_gb. The estimate cannot undercut the remaining weight bytes
// plus the native provider's declared, checkpoint-derived loading allowance.
// Missing/invalid declarations retain the existing 1.2 load-transient padding.
// Only the native Qwen4 family currently implements this declaration. A model
// name alone must not opt an unrelated loader into reduced admission accounting.
func advertisedOffloadedMemoryGBLocked(p *Provider, model string) float64 {
	for _, info := range p.Models {
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
	if math.IsNaN(*freeForLoadGB) || math.IsInf(*freeForLoadGB, 0) || *freeForLoadGB < 0 {
		return false, true
	}
	required := offloadedMemoryGB
	if !finitePositiveMemory(required) {
		if !finitePositiveMemory(catalogSizeGB) {
			return false, false
		}
		required = catalogSizeGB * coldLoadCatalogGBToMemGiB
	}
	return required <= *freeForLoadGB, true
}
