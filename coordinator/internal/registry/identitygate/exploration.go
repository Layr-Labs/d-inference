package identitygate

import (
	"math"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/measurements"
)

// Exploration memory survives idle evidence clearing and reconnects, but gates
// only evidence exploration, never ordinary routing or provider health.
const (
	firstContentExplorationBackoffBase     = 5 * time.Minute
	firstContentExplorationBackoffMax      = 2 * time.Hour
	firstContentExplorationRateSamples     = 8
	firstContentExplorationRateMinSamples  = 5
	firstContentExplorationSlowFraction    = 0.25
	firstContentExplorationHealthyFraction = 0.5
	firstContentExplorationMemoryTTL       = 6 * time.Hour
)

type firstContentExplorationEntry struct {
	level           int
	until           time.Time
	decode          []float64 // most recent measured rates, oldest first
	decodeUpdatedAt time.Time // actual observation or healthy clear, never an outcome touch
	touchedAt       time.Time
	decodeMarks     []decodeWatermark // at most eight producer epochs or legacy EWMA values
	// A merge may have more known producers than fit. Do not treat an omitted
	// producer as new until every omitted watermark could have expired.
	unknownProducerUntil time.Time
}

type decodeWatermark struct {
	epoch  string
	count  int64
	rate   float64 // legacy producers have no count; deduplicate their exact EWMA
	seenAt time.Time
}

func firstContentExplorationBackoff(level int) time.Duration {
	if level <= 0 {
		return 0
	}
	d := firstContentExplorationBackoffBase
	for i := 1; i < level && d < firstContentExplorationBackoffMax; i++ {
		d *= 2
	}
	return min(d, firstContentExplorationBackoffMax)
}

func (g *State) explorationEntryLocked(model string) *firstContentExplorationEntry {
	if g.exploration == nil {
		g.exploration = make(map[string]*firstContentExplorationEntry)
	}
	e := g.exploration[model]
	if e == nil {
		e = &firstContentExplorationEntry{}
		g.exploration[model] = e
	}
	return e
}

// RecordFirstContentExplorationOutcome records a delivered request or failed
// exploration (first-content timeout, deadline refusal, or genuine fault).
// Callers exclude neutral outcomes such as cancellation, speculative losers,
// and drain. Failures double suppression; success removes one backoff level.
func (r *Directory) RecordFirstContentExplorationOutcome(providerID, model string, ok bool) {
	if providerID == "" || model == "" {
		return
	}
	hold := r.lockGate(r.gateForSession(providerID), "first_content_exploration")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return
	}
	now := r.now()
	e := g.explorationEntryLocked(model)
	e.touchedAt = now
	if ok {
		e.level = max(0, e.level-1)
		if e.level == 0 {
			e.until = time.Time{}
		} else if limit := now.Add(firstContentExplorationBackoff(e.level)); e.until.After(limit) {
			e.until = limit
		}
	} else {
		if firstContentExplorationBackoff(e.level) < firstContentExplorationBackoffMax {
			e.level++
		}
		e.until = now.Add(firstContentExplorationBackoff(e.level))
	}
	g.updatedLocked(now)
}

// RecordFirstContentDecodeObservation remembers one distinct decode observation.
// Heartbeats capture ReferenceForSession under the provider lock, avoiding an
// index lookup on the common path. Validated locking follows stale references
// through rebinding or retirement rather than retaining a raw gate pointer.
// Explicit sample time orders rate evidence; legacy EWMAs have only arrival
// order and are conservatively deduplicated by value. Healthy writes retain a
// tombstone even without prior slow evidence, so later identity merges honor it.
func (r *Directory) RecordFirstContentDecodeObservation(ref Reference, observation measurements.DecodeObservation, fleetMedian float64, now time.Time) {
	if observation.Model == "" || !(observation.Rate > 0) || math.IsInf(observation.Rate, 0) {
		return
	}
	at := now
	if observation.Epoch != "" {
		at = observation.ObservedAfter
		if len(observation.Epoch) > 64 || observation.SampleCount <= 0 || at.IsZero() || at.After(now) || now.Sub(at) >= firstContentExplorationMemoryTTL {
			return
		}
	} else if observation.SampleCount != 0 {
		return
	}
	healthy := fleetMedian > 0 && observation.Rate >= firstContentExplorationHealthyFraction*fleetMedian
	hold := r.lockGate(ref, "first_content_decode_observation")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return
	}
	e := g.explorationEntryLocked(observation.Model)
	e.pruneDecode(now)
	defer g.publishLocked()
	mark := decodeWatermark{epoch: observation.Epoch, count: observation.SampleCount, rate: observation.Rate, seenAt: now}
	index := slices.IndexFunc(e.decodeMarks, func(m decodeWatermark) bool { return m.sameProducer(mark) })
	if index >= 0 {
		previous := &e.decodeMarks[index]
		if mark.epoch == "" || mark.count <= previous.count {
			return
		}
		*previous = mark
	} else if len(e.decodeMarks) < firstContentExplorationRateSamples && !now.Before(e.unknownProducerUntil) {
		e.decodeMarks = append(e.decodeMarks, mark)
	} else if !healthy || at.Before(e.decodeUpdatedAt) {
		// Saturation cannot manufacture corroboration by evicting and replaying
		// old epochs. Known producers can still advance, and recovery can clear.
		return
	} else {
		e.unknownProducerUntil = maxTime(e.unknownProducerUntil, now.Add(firstContentExplorationMemoryTTL))
	}
	e.touchedAt = now
	g.touched = now
	if at.Before(e.decodeUpdatedAt) {
		return
	}
	e.decodeUpdatedAt = at
	if healthy {
		e.decode = nil
		return
	}
	if len(e.decode) == firstContentExplorationRateSamples {
		copy(e.decode, e.decode[1:])
		e.decode[len(e.decode)-1] = observation.Rate
	} else {
		e.decode = append(e.decode, observation.Rate)
	}
}

func (m decodeWatermark) sameProducer(other decodeWatermark) bool {
	return m.epoch == other.epoch && (m.epoch != "" || m.rate == other.rate)
}

func maxTime(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

func (e *firstContentExplorationEntry) pruneDecode(now time.Time) {
	e.decodeMarks = slices.DeleteFunc(e.decodeMarks, func(m decodeWatermark) bool {
		return now.Sub(m.seenAt) >= firstContentExplorationMemoryTTL
	})
	if !now.Before(e.unknownProducerUntil) {
		e.unknownProducerUntil = time.Time{}
	}
	if !e.decodeUpdatedAt.IsZero() && now.Sub(e.decodeUpdatedAt) >= firstContentExplorationMemoryTTL {
		e.decode, e.decodeUpdatedAt = nil, time.Time{}
	}
}

// ExplorationView is an immutable snapshot of one identity/model's memory.
type ExplorationView struct {
	Suppressed    bool
	DecodeMedian  float64
	DecodeSamples int
}

// Exploration reads the memory without mutation. Empty identities avoid the
// gate lock; callers confirm a session-backed View before acting on it.
func (v View) Exploration(model string, now time.Time) ExplorationView {
	g := v.g.resolve()
	if !g.hasPairState(gateFlagExploration) {
		return ExplorationView{}
	}
	g = g.lockResolved()
	defer g.mu.Unlock()
	e := g.exploration[model]
	if e == nil {
		return ExplorationView{}
	}
	view := ExplorationView{Suppressed: now.Before(e.until), DecodeSamples: len(e.decode)}
	if len(e.decode) >= firstContentExplorationRateMinSamples {
		sorted := slices.Clone(e.decode)
		slices.Sort(sorted)
		view.DecodeMedian = sorted[len(sorted)/2]
	}
	return view
}

// RememberedSlow requires corroborated decode evidence below the model/chip
// family's fleet median. A single slow final decode never prevents exploration.
func (v ExplorationView) RememberedSlow(fleetMedian float64) bool {
	return v.DecodeSamples >= firstContentExplorationRateMinSamples &&
		fleetMedian > 0 && v.DecodeMedian > 0 && !math.IsInf(v.DecodeMedian, 0) &&
		v.DecodeMedian < firstContentExplorationSlowFraction*fleetMedian
}

func (g *State) pruneExplorationLocked(now time.Time) bool {
	for model, e := range g.exploration {
		e.pruneDecode(now)
		if !now.Before(e.until) && now.Sub(e.touchedAt) >= firstContentExplorationMemoryTTL {
			delete(g.exploration, model)
		}
	}
	return len(g.exploration) > 0
}

// mergeExplorationLocked retains the stricter suppression and newer rates.
// Caller holds both gates; samples must not alias a still-shared source gate.
func (g *State) mergeExplorationLocked(src *State) {
	for model, s := range src.exploration {
		e := g.explorationEntryLocked(model)
		e.level = max(e.level, s.level)
		if s.until.After(e.until) {
			e.until = s.until
		}
		if s.decodeUpdatedAt.After(e.decodeUpdatedAt) {
			e.decode = slices.Clone(s.decode)
			e.decodeUpdatedAt = s.decodeUpdatedAt
		}
		e.unknownProducerUntil = maxTime(e.unknownProducerUntil, s.unknownProducerUntil)
		for _, mark := range s.decodeMarks {
			index := slices.IndexFunc(e.decodeMarks, func(m decodeWatermark) bool { return m.sameProducer(mark) })
			if index >= 0 {
				e.decodeMarks[index].count = max(e.decodeMarks[index].count, mark.count)
				e.decodeMarks[index].seenAt = maxTime(e.decodeMarks[index].seenAt, mark.seenAt)
			} else if len(e.decodeMarks) < firstContentExplorationRateSamples {
				e.decodeMarks = append(e.decodeMarks, mark)
			} else {
				e.unknownProducerUntil = maxTime(e.unknownProducerUntil, mark.seenAt.Add(firstContentExplorationMemoryTTL))
			}
		}
		if s.touchedAt.After(e.touchedAt) {
			e.touchedAt = s.touchedAt
		}
	}
}
