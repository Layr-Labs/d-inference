package memorypolicy

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Footprint is the model's load quotation against current machine memory.
// Reservation and slot budgets are evaluated separately by Input.
type Footprint struct {
	TotalMemoryGB              float64
	ModelSizeGB                float64
	EstimatedOffloadedMemoryGB float64
	GPUMemoryActiveGB          float64
	FreeForLoadGB              *float64
}

// Resolve replaces the entire quotation, including optional backend evidence,
// so reused storage cannot carry another model's native allowance or headroom.
func (f *Footprint) Resolve(models []protocol.ModelInfo, model string, modelSizeGB, hardwareMemoryGB float64, backend *protocol.BackendCapacity) {
	*f = Footprint{
		TotalMemoryGB: hardwareMemoryGB, ModelSizeGB: modelSizeGB,
		EstimatedOffloadedMemoryGB: NativeLoadGB(models, model, modelSizeGB),
	}
	if backend != nil {
		f.GPUMemoryActiveGB = backend.GPUMemoryActiveGB
		f.FreeForLoadGB = backend.FreeForLoadGB
		if backend.TotalMemoryGB > 0 {
			f.TotalMemoryGB = backend.TotalMemoryGB
		}
	}
}
