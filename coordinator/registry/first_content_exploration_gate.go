package registry

import (
	"slices"
	"time"
)

// first_content_exploration_gate.go — per-identity memory that keeps
// evidence exploration (first_content_exploration.go) away from providers
// whose explorations fail.
//
// Exploration admits an idle provider without current performance evidence
// and prices it at the fleet median. Idle providers lose that evidence
// routinely (a typical one clears its decode rate a few times an hour), so a
// genuinely slow provider becomes explorable again and again. And a
// first-content timeout is a 429 that the node-health breaker deliberately
// ignores, because busy healthy providers time out too. One such provider —
// decoding at a tenth of its chip family's median — failed most of the
// explorations it received for hours without any tracker reacting.
//
// Two independent checks, both scoped to exploration only:
//
//   - Backoff on explored outcomes. A failed exploration (first-content
//     timeout, deadline refusal, genuine fault) doubles a per-model
//     suppression interval; a successful one halves it. A provider that fails
//     most explorations therefore stays suppressed, which reset-on-success
//     would not achieve: short requests still succeed now and then.
//   - Remembered decode rate. Measured decode rates are kept per model beyond
//     evidence clearing and reconnects. A corroborated median well below the
//     fleet median makes the provider non-explorable. One observation never
//     decides: a single slow final decode is the stale-estimate lock-out this
//     exploration exists to escape.
//
// Neither check quarantines anything. A suppressed provider keeps
// feasible-first behavior: it is still selected when no candidate is
// feasible. State lives on the stable-identity gate, so it survives
// reconnects; a provider binary version change clears it.
const (
	firstContentExplorationBackoffBase = 5 * time.Minute
	firstContentExplorationBackoffMax  = 2 * time.Hour
	// Remembered decode observations per model; the median of the most
	// recent samples decides once there are enough of them.
	firstContentExplorationRateSamples    = 8
	firstContentExplorationRateMinSamples = 5
	// Below this fraction of the (model, chip family) fleet decode median a
	// corroborated remembered rate makes the provider non-explorable. Policy,
	// set from production evidence, not a measured optimum.
	firstContentExplorationSlowFraction = 0.25
	// An observation at or above this fraction of the fleet median is
	// healthy evidence and clears the remembered rates.
	firstContentExplorationHealthyFraction = 0.5
	// Memory older than this with no active suppression is dropped.
	firstContentExplorationMemoryTTL = 6 * time.Hour
)

type firstContentExplorationEntry struct {
	level     int       // backoff doublings; 0 = none
	until     time.Time // exploration suppressed before this instant
	decode    []float64 // most recent measured decode rates, oldest first
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

func (g *gateState) explorationEntryLocked(model string, now time.Time) *firstContentExplorationEntry {
	if g.exploration == nil {
		g.exploration = make(map[string]*firstContentExplorationEntry)
	}
	e := g.exploration[model]
	if e == nil {
		e = &firstContentExplorationEntry{}
		g.exploration[model] = e
	}
	e.touchedAt = now
	return e
}

// RecordFirstContentExplorationOutcome feeds the outcome of an attempt that
// was selected through evidence exploration. ok is a delivered request;
// failures are first-content timeouts, deadline refusals and genuine faults.
// Neutral outcomes (client cancellation, speculative losers, drain) must not
// be recorded. Takes only the identity's gate.mu.
func (r *Registry) RecordFirstContentExplorationOutcome(providerID, model string, ok bool) {
	if providerID == "" || model == "" {
		return
	}
	hold := r.lockGate(r.gateForSession(providerID), "first_content_exploration")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return
	}
	now := time.Now()
	e := g.explorationEntryLocked(model, now)
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

// recordFirstContentDecodeObservationLocked remembers one newly measured
// decode rate. fleetMedian is the (model, chip family) median at that moment;
// a healthy observation relative to it clears the memory. Caller holds the
// session's p.mu (so p.gate cannot move) and no gate lock.
func (g *gateState) recordFirstContentDecodeObservation(model string, decode, fleetMedian float64, now time.Time) {
	if g == nil || model == "" || !finitePositive(decode) {
		return
	}
	healthy := fleetMedian > 0 && decode >= firstContentExplorationHealthyFraction*fleetMedian
	if healthy && !g.hasPairState(gateFlagExploration) {
		return // nothing remembered and nothing to remember: no lock section
	}
	g = g.lockResolved()
	defer g.mu.Unlock()
	if healthy {
		if e := g.exploration[model]; e != nil {
			e.decode = nil
			e.touchedAt = now
			g.updatedLocked(now)
		}
		return
	}
	e := g.explorationEntryLocked(model, now)
	e.decode = append(e.decode, decode)
	if n := len(e.decode); n > firstContentExplorationRateSamples {
		e.decode = append(e.decode[:0], e.decode[n-firstContentExplorationRateSamples:]...)
	}
	g.updatedLocked(now)
}

// firstContentExplorationView is what the scan copies into the snapshot.
type firstContentExplorationView struct {
	suppressed    bool
	decodeMedian  float64
	decodeSamples int
}

// explorationView reads one model's memory: a lock-free no-state fast path,
// otherwise one short gate.mu section. READ-ONLY. nil-safe.
func (g *gateState) explorationView(model string, now time.Time) firstContentExplorationView {
	if !g.hasPairState(gateFlagExploration) {
		return firstContentExplorationView{}
	}
	g = g.lockResolved()
	defer g.mu.Unlock()
	e := g.exploration[model]
	if e == nil {
		return firstContentExplorationView{}
	}
	v := firstContentExplorationView{suppressed: now.Before(e.until), decodeSamples: len(e.decode)}
	if len(e.decode) >= firstContentExplorationRateMinSamples {
		sorted := slices.Clone(e.decode)
		slices.Sort(sorted)
		v.decodeMedian = sorted[len(sorted)/2]
	}
	return v
}

// firstContentExplorationRememberedSlow reports a corroborated remembered
// decode rate far below the fleet median for the snapshot's model.
func firstContentExplorationRememberedSlow(s *routingSnapshot) bool {
	return s.exploration.decodeSamples >= firstContentExplorationRateMinSamples &&
		s.fleetMedianTPS > 0 && finitePositive(s.exploration.decodeMedian) &&
		s.exploration.decodeMedian < firstContentExplorationSlowFraction*s.fleetMedianTPS
}

// pruneExplorationLocked drops memory that can no longer influence routing.
// Reports whether any entry remains. Caller holds g.mu.
func (g *gateState) pruneExplorationLocked(now time.Time) (live bool) {
	for model, e := range g.exploration {
		if !now.Before(e.until) && now.Sub(e.touchedAt) >= firstContentExplorationMemoryTTL {
			delete(g.exploration, model)
		}
	}
	return len(g.exploration) > 0
}

// mergeExplorationLocked folds a migrated identity's memory into g, keeping
// the stricter suppression and the newer rates. Caller holds both gates.
func (g *gateState) mergeExplorationLocked(src *gateState) {
	for model, s := range src.exploration {
		prior := time.Time{}
		if cur := g.exploration[model]; cur != nil {
			prior = cur.touchedAt
		}
		e := g.explorationEntryLocked(model, prior)
		if s.level > e.level {
			e.level = s.level
		}
		if s.until.After(e.until) {
			e.until = s.until
		}
		if len(s.decode) > 0 && (len(e.decode) == 0 || s.touchedAt.After(prior)) {
			e.decode = slices.Clone(s.decode)
		}
		if s.touchedAt.After(e.touchedAt) {
			e.touchedAt = s.touchedAt
		}
	}
}

// SetFirstContentExplored records whether this attempt was selected through
// evidence exploration. The reservation commit sets it before dispatch; the
// attempt's own outcome paths read it.
func (pr *PendingRequest) SetFirstContentExplored(explored bool) {
	if pr != nil {
		pr.firstContentExplored = explored
	}
}

// FirstContentExplored reports whether this attempt was selected through
// evidence exploration.
func (pr *PendingRequest) FirstContentExplored() bool {
	return pr != nil && pr.firstContentExplored
}

// FirstContentExplorationSuppressed reports whether exploration is currently
// backed off for the session's identity and model. Read-only diagnostic.
func (r *Registry) FirstContentExplorationSuppressed(providerID, model string) bool {
	return r.lookupGateForSession(providerID).explorationView(model, time.Now()).suppressed
}

type firstContentDecodeMark struct {
	rate  float64
	count int64
}

// firstContentDecodeMarksLocked copies each model's measured decode rate and
// explicit sample count, so the heartbeat can tell a new observation from a
// repeated one. nil when nothing is measured. Caller holds p.mu.
func (p *Provider) firstContentDecodeMarksLocked() map[string]firstContentDecodeMark {
	if len(p.firstContentMeasurements) == 0 {
		return nil
	}
	marks := make(map[string]firstContentDecodeMark, len(p.firstContentMeasurements))
	for model, m := range p.firstContentMeasurements {
		marks[model] = firstContentDecodeMark{rate: m.decodeRate, count: m.decodeCount}
	}
	return marks
}

// noteFirstContentDecodeObservationsLocked remembers every decode rate that
// the heartbeat's reconcile newly measured: a positive rate that is new for
// the model, changed, or carries a higher explicit sample count. Caller holds
// p.mu, which pins p.gate for the section.
func (r *Registry) noteFirstContentDecodeObservationsLocked(p *Provider, before map[string]firstContentDecodeMark, now time.Time) {
	g := p.gate.Load()
	if g == nil {
		return
	}
	for model, m := range p.firstContentMeasurements {
		if !finitePositive(m.decodeRate) {
			continue
		}
		if prev, ok := before[model]; ok && prev.rate == m.decodeRate && m.decodeCount <= prev.count {
			continue
		}
		g.recordFirstContentDecodeObservation(model, m.decodeRate, r.tpsRegistry.Median(model, p.Hardware.ChipFamily), now)
	}
}

// ProviderOutcomeIsFault exposes the node-health breaker's fault test so the
// exploration hooks classify failures exactly as the breaker does.
func ProviderOutcomeIsFault(statusCode int, errStr string) bool {
	return providerOutcomeIsFault(statusCode, errStr)
}
