package capacityvalue

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// SampleHistory tracks accepted sample time, independently of connection
// liveness. Callers serialize it with the same lock as the capacity snapshot.
type SampleHistory struct{ acceptedAt time.Time }

func (h *SampleHistory) MarkAccepted(now time.Time) { h.acceptedAt = now }

func (h *SampleHistory) Fresh(now time.Time, maxAge time.Duration) bool {
	return h != nil && !h.acceptedAt.IsZero() && now.Sub(h.acceptedAt) <= maxAge
}

func (h *SampleHistory) Reconcile(previous, current *protocol.BackendCapacity, now time.Time) {
	var elapsed time.Duration
	if !h.acceptedAt.IsZero() {
		elapsed = now.Sub(h.acceptedAt)
	}
	ReconcileSamples(previous, current, elapsed)
	h.acceptedAt = time.Time{}
	if current != nil && (len(current.Slots) != 0 || (current.Telemetry != nil && current.Telemetry.ProcessMemory != nil)) {
		h.MarkAccepted(now)
	}
}

// ReconcileSamples is bounded by the live slot set. Coordinator elapsed time
// prevents heartbeats from freshening a stopped sample producer.
func ReconcileSamples(previous, current *protocol.BackendCapacity, elapsed time.Duration) {
	if previous == nil || current == nil {
		return
	}
	elapsedMS := uint64(max(0, elapsed.Milliseconds()))
	if previous.Telemetry != nil && current.Telemetry != nil {
		a, b := previous.Telemetry.ProcessMemory, current.Telemetry.ProcessMemory
		if a != nil && b != nil {
			if age, retain := RetainedSampleAge(SamplePosition{a.Generation, a.SampleSeq, a.SampleAgeMS}, SamplePosition{b.Generation, b.SampleSeq, b.SampleAgeMS}, elapsedMS); retain {
				current.Telemetry.ProcessMemory = a.Clone()
				current.Telemetry.ProcessMemory.SampleAgeMS = min(age, uint64(1<<53)-1)
			}
		}
	}
	for i := range current.Slots {
		cur := &current.Slots[i]
		for _, old := range previous.Slots {
			if old.Model != cur.Model {
				continue
			}
			if old.PrefixCache != nil && cur.PrefixCache != nil {
				a, b := old.PrefixCache, cur.PrefixCache
				if age, retain := RetainedSampleAge(SamplePosition{a.Generation, a.SampleSeq, a.SampleAgeMS}, SamplePosition{b.Generation, b.SampleSeq, b.SampleAgeMS}, elapsedMS); retain {
					cur.PrefixCache = a.Clone()
					cur.PrefixCache.SampleAgeMS = age
				}
			}
			if old.PagedStorage != nil && cur.PagedStorage != nil {
				a, b := old.PagedStorage, cur.PagedStorage
				if age, retain := RetainedSampleAge(SamplePosition{a.Generation, a.SampleSeq, a.SampleAgeMS}, SamplePosition{b.Generation, b.SampleSeq, b.SampleAgeMS}, elapsedMS); retain {
					cur.PagedStorage = a.Clone()
					cur.PagedStorage.SampleAgeMS = age
				}
			}
			break
		}
	}
}

type SamplePosition struct{ Generation, Sequence, AgeMS uint64 }

func RetainedSampleAge(old, current SamplePosition, elapsedMS uint64) (uint64, bool) {
	if current.Generation != old.Generation || current.Sequence > old.Sequence {
		return current.AgeMS, false
	}
	return max(current.AgeMS, min(MaxCapacitySampleValue, old.AgeMS+min(elapsedMS, MaxCapacitySampleValue))), true
}
