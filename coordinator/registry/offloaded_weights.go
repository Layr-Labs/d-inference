package registry

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"
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
	return memorypolicy.NativeLoadGB(p.Models, model, catalogSizeGB...)
}

func reportedFreeForLoadAdmitsWithOffload(catalogSizeGB, offloadedMemoryGB float64, freeForLoadGB *float64) (bool, bool) {
	if freeForLoadGB == nil {
		return false, false
	}
	return admission.ReportedLoadAdmits(catalogSizeGB, offloadedMemoryGB, *freeForLoadGB, true)
}
