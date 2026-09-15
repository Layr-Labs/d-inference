package mdm

import "github.com/eigeninference/d-inference/coordinator/hardware"

// ModelMaxMemoryGB remains a compatibility entry point. The hardware catalog
// and base-reward memory cap no longer depend on MDM enrollment or services.
func ModelMaxMemoryGB(model string) (int, bool) { return hardware.ModelMaxMemoryGB(model) }
