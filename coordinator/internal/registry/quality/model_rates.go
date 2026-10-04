package quality

import "github.com/eigeninference/d-inference/coordinator/protocol"

// ModelRates prefers positive observations from the matching model's slot.
func ModelRates(model string, capacity *protocol.BackendCapacity, decode, prefill float64) (float64, float64) {
	if capacity == nil {
		return decode, prefill
	}
	for _, slot := range capacity.Slots {
		if slot.Model != model {
			continue
		}
		if slot.ObservedDecodeTPS > 0 {
			decode = slot.ObservedDecodeTPS
		}
		if slot.ObservedPrefillTPS > 0 {
			prefill = slot.ObservedPrefillTPS
		}
		break
	}
	return decode, prefill
}
