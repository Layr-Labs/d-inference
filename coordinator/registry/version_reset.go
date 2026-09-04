package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Version changes clear only disconnect-flush faults, at most once per
// identityVersionResetMinInterval. Reset history and fault mutations share
// gate.mu so a trailing old-session 502 cannot re-poison a new binary.
const disconnectFlushStatusCode = 502
const identityVersionResetMinInterval = 10 * time.Minute

// Only the non-wire coordinator cause can identify a disconnect flush.
// A provider-authored 502 (including encryption failure) is a genuine fault.
func isDisconnectFlush(statusCode int, causes []protocol.CoordinatorInferenceErrorCause) bool {
	return statusCode == disconnectFlushStatusCode && len(causes) == 1 &&
		causes[0] == protocol.CoordinatorCauseProviderDisconnected
}

// SetVersion observes the bound identity while p.mu excludes a concurrent
// rebind. The index lock stabilizes lookup until the gate has been acquired.
func (p *Provider) SetVersion(version string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.Version = version
	r := p.registry
	if r == nil || version == "" {
		return
	}
	r.gatesMu.RLock()
	if r.sessions[p.ID] != p {
		r.gatesMu.RUnlock()
		return
	}
	g := p.gate.Load()
	if g == nil || g.key == p.ID {
		r.gatesMu.RUnlock()
		return
	}
	g = g.lockResolved()
	r.gatesMu.RUnlock()
	defer g.mu.Unlock()
	now := time.Now()
	g.noteIdentityVersionLocked(r, version)
	g.updatedLocked(now)
}

// disconnectSource captures the session while holding the index lock. A live
// reference can disconnect after lookup; its atomic timestamp then supplies
// the drop time without taking p.mu while a recorder holds gate.mu.
type disconnectSource struct {
	p  *Provider
	at time.Time
}

func (r *Registry) captureDisconnectSource(sessionID string) disconnectSource {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	if p := r.sessions[sessionID]; p != nil {
		return disconnectSource{p: p}
	}
	return disconnectSource{at: r.disconnectedStableIDs[sessionID].at}
}
func (source disconnectSource) supersededBy(g *gateState) bool {
	at := source.at
	if source.p != nil {
		if ns := source.p.gateDisconnectedAtNS.Load(); ns != 0 {
			at = time.Unix(0, ns)
		}
	}
	return g != nil && !at.IsZero() && !g.versionResetAt.IsZero() && !g.versionResetAt.Before(at)
}
func (r *Registry) IsSupersededDisconnectFlush(sessionID string, statusCode int, causes ...protocol.CoordinatorInferenceErrorCause) bool {
	if !isDisconnectFlush(statusCode, causes) || sessionID == "" {
		return false
	}
	source := r.captureDisconnectSource(sessionID)
	ref := r.lookupSessionGateRef(sessionID)
	if ref.g == nil {
		return false
	}
	hold := r.lockGate(ref, "disconnect_flush")
	defer hold.unlock()
	return source.supersededBy(hold.g)
}

func (g *gateState) noteIdentityVersionLocked(r *Registry, version string) {
	if version == "" {
		return
	}
	previous := g.identityVersion
	g.identityVersion = version
	if previous == "" || previous == version {
		return
	}
	// Date the reset at its mutation boundary, after gate acquisition. A bind
	// can wait behind a disconnect on the index; its earlier lookup timestamp
	// must not make a reset performed afterward predate that disconnect.
	now := time.Now()
	if !g.versionResetAt.IsZero() && now.Sub(g.versionResetAt) < identityVersionResetMinInterval {
		r.logger.Warn("provider version changed again within the reset interval: disconnect-flush strikes retained",
			"stable_id", g.key, "previous_version", previous, "version", version, "since_last_reset", now.Sub(g.versionResetAt))
		return
	}
	g.versionResetAt = now
	if g.clearDisconnectFlushStrikesLocked(now) {
		r.logger.Info("provider reconnected on a new binary version: disconnect-flush strikes cleared from its fault trackers",
			"stable_id", g.key, "previous_version", previous, "version", version)
	}
}

func (g *gateState) noteInferenceFlushStrikeLocked(key modelShapeKey, at time.Time) {
	if g.inferenceErrorFlushStrikes == nil {
		g.inferenceErrorFlushStrikes = make(map[modelShapeKey][]time.Time)
	}
	g.inferenceErrorFlushStrikes[key] = append(g.inferenceErrorFlushStrikes[key], at)
}
func (g *gateState) pruneInferenceFlushStrikesLocked(key modelShapeKey, now time.Time) {
	flush := g.inferenceErrorFlushStrikes[key]
	kept := flush[:0]
	for _, stamp := range flush {
		if now.Sub(stamp) < inferenceErrorWindow {
			kept = append(kept, stamp)
		}
	}
	if len(kept) == 0 {
		delete(g.inferenceErrorFlushStrikes, key)
	} else {
		g.inferenceErrorFlushStrikes[key] = kept
	}
}

func (g *gateState) clearDisconnectFlushStrikesLocked(now time.Time) (cleared bool) {
	for key, flush := range g.inferenceErrorFlushStrikes {
		delete(g.inferenceErrorFlushStrikes, key)
		strikes := g.inferenceErrorStrikes[key]
		kept := strikes[:0]
		for _, stamp := range strikes {
			if !containsTimestamp(flush, stamp) {
				kept = append(kept, stamp)
			}
		}
		if len(kept) == len(strikes) {
			continue
		}
		cleared = true
		if len(kept) == 0 {
			delete(g.inferenceErrorStrikes, key)
		} else {
			g.inferenceErrorStrikes[key] = kept
		}
		inWindow := 0
		for _, stamp := range kept {
			if now.Sub(stamp) < inferenceErrorWindow {
				inWindow++
			}
		}
		if inWindow < inferenceErrorThreshold {
			delete(g.inferenceErrorCooldowns, key)
		}
	}
	if w := g.outcomes; w != nil && w.dropFlushFaults() {
		cleared = true
		total, fails := w.windowStats(now, providerBreakerWindow)
		rateTrip := total >= providerBreakerMinVolume && float64(fails) > providerBreakerFailRate*float64(total)
		if w.consecFail < providerBreakerConsecTrip && !rateTrip {
			g.breakerUntil = time.Time{}
			g.breakerTrips = 0
		}
	}
	if w := g.ejection; w != nil && w.dropFlushFaults() {
		cleared = true
		total, fails := w.windowStats(now, healthEjectionWindow)
		rateTrip := total >= healthEjectionMinSample && float64(total-fails) < healthEjectionMinSuccessRate*float64(total)
		if !g.ejectionLastTripCapacity && w.consecFail < healthEjectionConsecTrip && !rateTrip {
			g.ejectionUntil = time.Time{}
			g.ejectionTrips = 0
			g.ejectionLastTripCapacity = false
		}
	}
	return cleared
}

// dropFlushFaults rebuilds the ring without its disconnect-flush faults and
// recomputes consecFail as the remaining tail's trailing fault run. Returns
// whether any entry was dropped.
func (w *providerHealthWindow) dropFlushFaults() (dropped bool) {
	entries := w.chronological()
	kept := entries[:0]
	for _, o := range entries {
		if o.flush {
			dropped = true
			continue
		}
		kept = append(kept, o)
	}
	if !dropped {
		return false
	}
	*w = providerHealthWindow{}
	for _, o := range kept {
		w.outcomes[w.head] = o
		w.head = (w.head + 1) % providerHealthRingSize
		w.size++
		if o.ok {
			w.consecFail = 0
		} else {
			w.consecFail++
		}
	}
	return true
}

// containsTimestamp reports whether ts equals any entry in list. Flush strikes
// are appended with the exact time.Time value the main strike list received,
// so equality identifies the same strike.
func containsTimestamp(list []time.Time, ts time.Time) bool {
	for _, t := range list {
		if t.Equal(ts) {
			return true
		}
	}
	return false
}
