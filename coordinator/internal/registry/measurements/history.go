// Package measurements owns the lifetime and freshness of provider rate evidence.
package measurements

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Sample is detached evidence for one model, not a heartbeat receipt timestamp.
type Sample struct {
	Epoch                  string
	PrefillCount           int64
	DecodeCount            int64
	Rate                   float64
	DecodeRate             float64
	ContendedCount         int64
	ContendedRate          float64
	ObservedAfter          time.Time
	DecodeObservedAfter    time.Time
	ContendedObservedAfter time.Time
}

// DecodeObservation is a newly measured rate, not a repeated heartbeat value.
// Identity-local exploration memory retains these beyond serving-set resets.
type DecodeObservation struct {
	Model string
	Rate  float64
}

// History is serialized by its provider's existing critical section. Reconcile
// replaces the serving set so eviction and omitted capacity discard evidence.
type History struct {
	samples map[string]Sample
}

func (h *History) Lookup(model string) (Sample, bool) {
	if h == nil {
		return Sample{}, false
	}
	sample, ok := h.samples[model]
	return sample, ok
}

func (h *History) Count() int {
	if h == nil {
		return 0
	}
	return len(h.samples)
}

func (h *History) Reset() {
	if h != nil {
		h.samples = nil
	}
}

// Reconcile uses explicit age/count/epoch metadata when available. Legacy
// providers cannot prove recency with a first report or an unchanged EWMA.
func (h *History) Reconcile(capacity *protocol.BackendCapacity, previousAcceptedAt, now time.Time, handoff time.Duration) []DecodeObservation {
	if capacity == nil {
		h.Reset()
		return nil
	}
	next := make(map[string]Sample, len(capacity.Slots))
	for _, slot := range capacity.Slots {
		if (slot.State != "running" && slot.State != "idle") || slot.Telemetry == nil {
			continue
		}
		old, exists := h.samples[slot.Model]
		measurement := Sample{}
		if explicit := slot.PerformanceMeasurements; explicit != nil {
			measurement.Epoch = explicit.Epoch
			sameEpoch := exists && old.Epoch == explicit.Epoch && explicit.Epoch != ""
			if explicit.Epoch != "" && len(explicit.Epoch) <= 64 {
				measurement.ObservedAfter, measurement.PrefillCount = explicitMeasurementTime(
					explicit.IsolatedPrefill, old.PrefillCount, old.Rate, old.ObservedAfter, now, sameEpoch, handoff)
				measurement.DecodeObservedAfter, measurement.DecodeCount = explicitMeasurementTime(
					explicit.Decode, old.DecodeCount, old.DecodeRate, old.DecodeObservedAfter, now, sameEpoch, handoff)
				measurement.ContendedObservedAfter, measurement.ContendedCount = explicitMeasurementTime(
					explicit.ContendedPrefill, old.ContendedCount, old.ContendedRate, old.ContendedObservedAfter, now, sameEpoch, handoff)
				if explicit.IsolatedPrefill != nil {
					measurement.Rate = explicit.IsolatedPrefill.TokensPerSecond
				}
				if explicit.Decode != nil {
					measurement.DecodeRate = explicit.Decode.TokensPerSecond
				}
				if explicit.ContendedPrefill != nil {
					measurement.ContendedRate = explicit.ContendedPrefill.TokensPerSecond
				}
			} else if exists {
				// Invalid metadata withdraws freshness, not the producer high-water
				// marks: replaying a prior valid report must not mint new evidence.
				measurement.Epoch = old.Epoch
				measurement.PrefillCount = old.PrefillCount
				measurement.DecodeCount = old.DecodeCount
				measurement.ContendedCount = old.ContendedCount
			}
			next[slot.Model] = measurement
			continue
		}
		if slot.Telemetry.EWMAInitialized == nil || !*slot.Telemetry.EWMAInitialized ||
			slot.Telemetry.IsolatedPrefillTPS == nil || !capacityvalue.FinitePositive(*slot.Telemetry.IsolatedPrefillTPS) ||
			*slot.Telemetry.IsolatedPrefillTPS > capacityvalue.MaxPrefillTPS {
			continue
		}
		rate := *slot.Telemetry.IsolatedPrefillTPS
		measurement.Rate, measurement.DecodeRate = rate, slot.ObservedDecodeTPS
		// A legacy report cannot borrow the previous explicit producer epoch.
		if exists && old.Epoch == "" {
			measurement.ObservedAfter = old.ObservedAfter
			measurement.DecodeObservedAfter = old.DecodeObservedAfter
			if old.Rate != rate && !previousAcceptedAt.IsZero() {
				measurement.ObservedAfter = previousAcceptedAt
			}
			if old.DecodeRate != slot.ObservedDecodeTPS && capacityvalue.FinitePositive(slot.ObservedDecodeTPS) && !previousAcceptedAt.IsZero() {
				measurement.DecodeObservedAfter = previousAcceptedAt
			}
		}
		if !capacityvalue.FinitePositive(slot.ObservedDecodeTPS) {
			measurement.DecodeObservedAfter = time.Time{}
		}
		next[slot.Model] = measurement
	}
	var observed []DecodeObservation
	for model, sample := range next {
		if !capacityvalue.FinitePositive(sample.DecodeRate) {
			continue
		}
		previous, exists := h.samples[model]
		if sample.Epoch != "" {
			// Explicit evidence must pass the same age/count/epoch validation
			// as its freshness clock. Changed-rate replays are not new samples.
			if sample.DecodeObservedAfter.IsZero() || (exists && previous.Epoch == sample.Epoch && sample.DecodeCount <= previous.DecodeCount) {
				continue
			}
		} else if exists && previous.DecodeRate == sample.DecodeRate {
			continue
		}
		observed = append(observed, DecodeObservation{Model: model, Rate: sample.DecodeRate})
	}
	h.samples = next
	return observed
}

// Unchanged samples can only get older. Changed rates with unchanged counts
// cannot create fresh evidence; handoff conservatively includes delivery time.
func explicitMeasurementTime(o *protocol.PerformanceRateObservation, oldCount int64, oldRate float64,
	oldAt, now time.Time, sameEpoch bool, handoff time.Duration) (time.Time, int64) {
	if !capacityvalue.ValidPerformanceObservation(o) {
		if sameEpoch {
			return time.Time{}, oldCount
		}
		return time.Time{}, 0
	}
	at := now.Add(-time.Duration(o.SampleAgeMS)*time.Millisecond - handoff)
	if sameEpoch {
		if o.SampleCount < oldCount || (o.SampleCount == oldCount && o.TokensPerSecond != oldRate) {
			return time.Time{}, oldCount
		}
		if o.SampleCount == oldCount {
			if oldAt.IsZero() {
				return time.Time{}, oldCount
			}
			if oldAt.Before(at) {
				at = oldAt
			}
		}
	}
	return at, o.SampleCount
}
