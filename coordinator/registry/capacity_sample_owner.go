package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"

func (r *Registry) newCapacitySamples(id string) *capacityvalue.SampleHistory {
	if r.capacitySamplesFactory != nil {
		return r.capacitySamplesFactory(id)
	}
	return &capacityvalue.SampleHistory{}
}
