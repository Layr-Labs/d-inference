package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Broad physical/cumulative limits bound untrusted observations without
// affecting admission. Missing instrumentation remains distinct from zero.
const maxCapacitySampleValue = uint64(1 << 60)
const maxCapacitySampleGaugeBytes = uint64(1 << 50)

// Called only for accepted replacements under p.mu. Rejected capacity frames
// advance liveness independently and leave this clock untouched.
func (p *Provider) reconcileCapacitySamplesLocked(current *protocol.BackendCapacity, now time.Time) {
	var elapsed time.Duration
	if !p.capacitySamplesAt.IsZero() {
		elapsed = now.Sub(p.capacitySamplesAt)
	}
	reconcileCapacitySamples(p.BackendCapacity, current, elapsed)
	p.capacitySamplesAt = time.Time{}
	if current != nil && (len(current.Slots) != 0 || (current.Telemetry != nil && current.Telemetry.ProcessMemory != nil)) {
		p.capacitySamplesAt = now
	}
}

// Reconciliation is bounded by the live slot set. Missing slots/samples clear
// their baseline; generation changes start a new one. Coordinator elapsed time
// prevents continuing heartbeats from freshening a stopped sample producer.
func reconcileCapacitySamples(previous, current *protocol.BackendCapacity, elapsed time.Duration) {
	if previous == nil || current == nil {
		return
	}
	elapsedMS := uint64(max(0, elapsed.Milliseconds()))
	if previous.Telemetry != nil && current.Telemetry != nil {
		a, b := previous.Telemetry.ProcessMemory, current.Telemetry.ProcessMemory
		if a != nil && b != nil {
			if age, retain := retainedSampleAge(
				samplePosition{a.Generation, a.SampleSeq, a.SampleAgeMS},
				samplePosition{b.Generation, b.SampleSeq, b.SampleAgeMS}, elapsedMS); retain {
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
				if age, retain := retainedSampleAge(
					samplePosition{a.Generation, a.SampleSeq, a.SampleAgeMS},
					samplePosition{b.Generation, b.SampleSeq, b.SampleAgeMS}, elapsedMS); retain {
					cur.PrefixCache = a.Clone()
					cur.PrefixCache.SampleAgeMS = age
				}
			}
			if old.PagedStorage != nil && cur.PagedStorage != nil {
				a, b := old.PagedStorage, cur.PagedStorage
				if age, retain := retainedSampleAge(
					samplePosition{a.Generation, a.SampleSeq, a.SampleAgeMS},
					samplePosition{b.Generation, b.SampleSeq, b.SampleAgeMS}, elapsedMS); retain {
					cur.PagedStorage = a.Clone()
					cur.PagedStorage.SampleAgeMS = age
				}
			}
			break
		}
	}
}

type samplePosition struct {
	generation, sequence, ageMS uint64
}

func retainedSampleAge(old, current samplePosition, elapsedMS uint64) (uint64, bool) {
	if current.generation != old.generation || current.sequence > old.sequence {
		return current.ageMS, false
	}
	return max(current.ageMS, min(maxCapacitySampleValue, old.ageMS+min(elapsedMS, maxCapacitySampleValue))), true
}
