package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Caller holds p.mu. Evidence is reconciled before the accepted receipt clock
// advances, preserving the preceding report's lower bound for legacy EWMAs.
func (p *Provider) reconcileFirstContentMeasurementsLocked(capacity *protocol.BackendCapacity, receivedAt ...time.Time) {
	now := time.Now()
	if len(receivedAt) > 0 {
		now = receivedAt[0]
	}
	if p.firstContentMeasurements == nil {
		p.firstContentMeasurements = &measurements.History{}
	}
	p.firstContentMeasurements.Reconcile(capacity, p.CapacityAcceptedAt, now,
		time.Duration(firstContentConservativeHandoffMs)*time.Millisecond)
}

func (r *Registry) newMeasurementHistory(sessionID string) *measurements.History {
	if r.measurementsFactory != nil {
		if history := r.measurementsFactory(sessionID); history != nil {
			return history
		}
	}
	return &measurements.History{}
}
