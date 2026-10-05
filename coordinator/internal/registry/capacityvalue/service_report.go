package capacityvalue

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// ServiceReport borrows a producer report validated within one provider critical
// section. It must not outlive that section or be reused after capacity mutation.
// Exact lease IDs still establish overlap; receipt time never does.
type ServiceReport struct {
	capacity *protocol.BackendCapacity
	valid    bool
}

func NewServiceReport(capacity *protocol.BackendCapacity) ServiceReport {
	report := ServiceReport{capacity: capacity}
	if capacity == nil || capacity.WholeMacServiceUsed == nil {
		return report
	}
	used := *capacity.WholeMacServiceUsed
	report.valid = !math.IsNaN(used) && !math.IsInf(used, 0) && used >= 0 && used <= 1+1e-12 &&
		ValidWholeMacServiceReservations(capacity)
	return report
}

// ValidFor refuses evidence borrowed from a different capacity owner.
func (r ServiceReport) ValidFor(capacity *protocol.BackendCapacity) bool {
	return r.valid && r.capacity == capacity
}
