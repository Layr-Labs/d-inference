package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type firstContentMeasurement struct {
	rate       float64
	decodeRate float64
	// The previous report is a lower bound on when a changed EWMA could have
	// been sampled. Using the new heartbeat time would incorrectly rejuvenate
	// a measurement after a long gap in capacity reports.
	observedAfter       time.Time
	decodeObservedAfter time.Time
}

// reconcileFirstContentMeasurementsLocked observes changes in the isolated
// prefill and decode EWMAs independently. Existing providers have no sample-age
// field: the first report
// alone cannot prove recency, and identical later heartbeats cannot renew it.
// A changed finite EWMA between two accepted reports supplies bounded local
// age evidence. Reconnect, missing capacity, and model eviction clear evidence.
func (p *Provider) reconcileFirstContentMeasurementsLocked(capacity *protocol.BackendCapacity) {
	if capacity == nil {
		p.firstContentMeasurements = nil
		return
	}
	next := make(map[string]firstContentMeasurement, len(capacity.Slots))
	for _, slot := range capacity.Slots {
		if !slotStateModelLoaded(slot.State) || slot.Telemetry == nil || slot.Telemetry.EWMAInitialized == nil || !*slot.Telemetry.EWMAInitialized ||
			slot.Telemetry.IsolatedPrefillTPS == nil || !finitePositive(*slot.Telemetry.IsolatedPrefillTPS) ||
			*slot.Telemetry.IsolatedPrefillTPS > maxPrefillTPS {
			continue
		}
		rate := *slot.Telemetry.IsolatedPrefillTPS
		old, exists := p.firstContentMeasurements[slot.Model]
		measurement := firstContentMeasurement{rate: rate, decodeRate: slot.ObservedDecodeTPS}
		if exists {
			measurement.observedAfter = old.observedAfter
			measurement.decodeObservedAfter = old.decodeObservedAfter
			if old.rate != rate && !p.CapacityAcceptedAt.IsZero() {
				measurement.observedAfter = p.CapacityAcceptedAt
			}
			if old.decodeRate != slot.ObservedDecodeTPS && finitePositive(slot.ObservedDecodeTPS) && !p.CapacityAcceptedAt.IsZero() {
				measurement.decodeObservedAfter = p.CapacityAcceptedAt
			}
		}
		if !finitePositive(slot.ObservedDecodeTPS) {
			measurement.decodeObservedAfter = time.Time{}
		}
		next[slot.Model] = measurement
	}
	p.firstContentMeasurements = next
}
