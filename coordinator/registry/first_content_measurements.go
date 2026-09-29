package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type firstContentMeasurement struct {
	epoch        string
	prefillCount int64
	decodeCount  int64
	rate         float64
	decodeRate   float64
	// The previous report is a lower bound on when a changed EWMA could have
	// been sampled. Using the new heartbeat time would incorrectly rejuvenate
	// a measurement after a long gap in capacity reports.
	observedAfter       time.Time
	decodeObservedAfter time.Time
}

// reconcileFirstContentMeasurementsLocked uses explicit age/count/epoch metadata
// when available. Legacy providers have no sample-age field: the first report
// alone cannot prove recency, and identical later heartbeats cannot renew it.
// A changed finite EWMA between two accepted reports supplies bounded local
// age evidence. Reconnect, missing capacity, and model eviction clear evidence.
func (p *Provider) reconcileFirstContentMeasurementsLocked(capacity *protocol.BackendCapacity, receivedAt ...time.Time) {
	now := time.Now()
	if len(receivedAt) > 0 {
		now = receivedAt[0]
	}
	if capacity == nil {
		p.firstContentMeasurements = nil
		return
	}
	next := make(map[string]firstContentMeasurement, len(capacity.Slots))
	for _, slot := range capacity.Slots {
		if !slotStateModelLoaded(slot.State) || slot.Telemetry == nil {
			continue
		}
		old, exists := p.firstContentMeasurements[slot.Model]
		measurement := firstContentMeasurement{}
		if explicit := slot.PerformanceMeasurements; explicit != nil {
			measurement.epoch = explicit.Epoch
			sameEpoch := exists && old.epoch == explicit.Epoch && explicit.Epoch != ""
			if explicit.Epoch != "" && len(explicit.Epoch) <= 64 {
				measurement.observedAfter, measurement.prefillCount = explicitMeasurementTime(
					explicit.IsolatedPrefill, old.prefillCount, old.rate, old.observedAfter, now, sameEpoch)
				measurement.decodeObservedAfter, measurement.decodeCount = explicitMeasurementTime(
					explicit.Decode, old.decodeCount, old.decodeRate, old.decodeObservedAfter, now, sameEpoch)
				if explicit.IsolatedPrefill != nil {
					measurement.rate = explicit.IsolatedPrefill.TokensPerSecond
				}
				if explicit.Decode != nil {
					measurement.decodeRate = explicit.Decode.TokensPerSecond
				}
			}
			next[slot.Model] = measurement
			continue
		}
		if slot.Telemetry.EWMAInitialized == nil || !*slot.Telemetry.EWMAInitialized ||
			slot.Telemetry.IsolatedPrefillTPS == nil || !finitePositive(*slot.Telemetry.IsolatedPrefillTPS) ||
			*slot.Telemetry.IsolatedPrefillTPS > maxPrefillTPS {
			continue
		}
		rate := *slot.Telemetry.IsolatedPrefillTPS
		measurement.rate, measurement.decodeRate = rate, slot.ObservedDecodeTPS
		// Switching from explicit producer metadata to a legacy report cannot
		// borrow the previous epoch's measurement time.
		if exists && old.epoch == "" {
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
