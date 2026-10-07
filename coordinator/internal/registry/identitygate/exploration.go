package identitygate

import (
	"math"
	"slices"
	"time"
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
	level     int
	until     time.Time
	decode    []float64 // most recent measured rates, oldest first
	touchedAt time.Time
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

// RecordFirstContentDecodeObservation remembers one newly measured decode rate.
// Heartbeats capture ReferenceForSession under the provider lock, avoiding an
// index lookup on the common path. Validated locking follows stale references
// through rebinding or retirement rather than retaining a raw gate pointer.
func (r *Directory) RecordFirstContentDecodeObservation(ref Reference, model string, decode, fleetMedian float64, now time.Time) {
	if model == "" || !(decode > 0) || math.IsInf(decode, 0) {
		return
	}
	healthy := fleetMedian > 0 && decode >= firstContentExplorationHealthyFraction*fleetMedian
	if healthy {
		var has bool
		ref, has = r.refHasPairState(ref, gateFlagExploration)
		if !has {
			return
		}
	}
	hold := r.lockGate(ref, "first_content_decode_observation")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return
	}
	if healthy {
		if e := g.exploration[model]; e != nil {
			e.decode = nil
			e.touchedAt = now
			g.updatedLocked(now)
		}
		return
	}
	e := g.explorationEntryLocked(model)
	e.touchedAt = now
	if len(e.decode) == firstContentExplorationRateSamples {
		copy(e.decode, e.decode[1:])
		e.decode[len(e.decode)-1] = decode
	} else {
		e.decode = append(e.decode, decode)
	}
	g.updatedLocked(now)
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
		if len(s.decode) > 0 && (len(e.decode) == 0 || s.touchedAt.After(e.touchedAt)) {
			e.decode = slices.Clone(s.decode)
		}
		if s.touchedAt.After(e.touchedAt) {
			e.touchedAt = s.touchedAt
		}
	}
}
