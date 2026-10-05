package rewardpolicy

import (
	"github.com/eigeninference/d-inference/coordinator/hardware"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func RewardMemoryGB(p registry.ProviderSnapshot) (int, bool) {
	capGB, known := hardware.ModelMaxMemoryGB(p.HardwareModel)
	if !known || p.MemoryGB <= 0 {
		return 0, false
	}
	if capGB > 0 {
		return min(p.MemoryGB, capGB), true
	}
	return p.MemoryGB, true
}
