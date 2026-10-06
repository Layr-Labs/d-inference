package identitygate

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

// ObserveVersion observes a live session's bound identity. The caller excludes
// concurrent provider rebinding; the index lock stabilizes lookup until the
// gate has been acquired.
func (r *Directory) ObserveVersion(p *Session, version string) {
	if r == nil || p == nil || version == "" {
		return
	}
	r.gatesMu.RLock()
	if r.sessions[p.id] != p {
		r.gatesMu.RUnlock()
		return
	}
	g := p.gate.Load()
	if g == nil || g.key == p.id {
		r.gatesMu.RUnlock()
		return
	}
	g = g.lockResolved()
	r.gatesMu.RUnlock()
	defer g.mu.Unlock()
	now := r.now()
	g.noteIdentityVersionLocked(r, version)
	g.updatedLocked(now)
}

// DisconnectSource captures the session while holding the index lock. A live
// reference can disconnect after lookup; its atomic timestamp then supplies
// the drop time without taking a provider lock while a recorder holds gate.mu.
type DisconnectSource struct {
	p  *Session
	at time.Time
}

func (r *Directory) CaptureDisconnectSource(sessionID string) DisconnectSource {
	r.gatesMu.RLock()
	defer r.gatesMu.RUnlock()
	if p := r.sessions[sessionID]; p != nil {
		return DisconnectSource{p: p}
	}
	return DisconnectSource{at: r.disconnectedStableIDs[sessionID].at}
}

// OccurredAt resolves the captured event, including a session that disconnected
// after capture. Keep the atomic read at the point the event is evaluated.
func (source DisconnectSource) OccurredAt() time.Time {
	at := source.at
	if source.p != nil {
		if ns := source.p.gateDisconnectedAtNS.Load(); ns != 0 {
			at = time.Unix(0, ns)
		}
	}
	return at
}
func (source DisconnectSource) supersededBy(g *State) bool {
	at := source.OccurredAt()
	return g != nil && g.version.Supersedes(at)
}
func (r *Directory) IsSupersededDisconnectFlush(sessionID string, statusCode int, causes ...protocol.CoordinatorInferenceErrorCause) bool {
	if !isDisconnectFlush(statusCode, causes) || sessionID == "" {
		return false
	}
	source := r.CaptureDisconnectSource(sessionID)
	ref := r.lookupSessionGateRef(sessionID)
	return r.SupersedesDisconnect(ref, source)
}

// SupersedesDisconnect checks a captured outcome's epoch against the validated
// identity it will actually reach, including enrichment after disconnection.
func (r *Directory) SupersedesDisconnect(ref Reference, source DisconnectSource) bool {
	if ref.g == nil {
		return false
	}
	hold := r.lockGate(ref, "disconnect_flush")
	defer hold.unlock()
	return source.supersededBy(hold.g)
}

func (g *State) noteIdentityVersionLocked(r *Directory, version string) {
	observation := g.version.Observe(version, r.now)
	if !observation.Changed {
		return
	}
	if observation.Throttled {
		r.logger.Warn("provider version changed again within the reset interval: disconnect-flush strikes retained",
			"stable_id", g.key, "previous_version", observation.Previous, "version", observation.Version, "since_last_reset", observation.SinceLastReset)
		return
	}
	if observation.Reset && g.clearDisconnectFlushStrikesLocked(observation.ResetAt) {
		r.logger.Info("provider reconnected on a new binary version: disconnect-flush strikes cleared from its fault trackers",
			"stable_id", g.key, "previous_version", observation.Previous, "version", observation.Version)
	}
}

func (g *State) clearDisconnectFlushStrikesLocked(now time.Time) (cleared bool) {
	cleared = g.inference.DropDisconnectFlush(now)
	if w := g.outcomes; w != nil && w.DropDisconnectFlush() {
		cleared = true
		assessment := g.breakerAssessmentLocked(now)
		if assessment.ConsecutiveFaults < ProviderBreakerConsecTrip && !assessment.breakerRateTrips() {
			g.breakerUntil = time.Time{}
			g.breakerTrips = 0
		}
	}
	if w := g.ejection; w != nil && w.DropDisconnectFlush() {
		cleared = true
		assessment := g.ejectionAssessmentLocked(now)
		if !assessment.CapacityOrigin && assessment.ConsecutiveFaults < healthEjectionConsecTrip && !assessment.ejectionRateTrips() {
			g.ejectionUntil = time.Time{}
			g.ejectionTrips = 0
			g.ejectionLastTripCapacity = false
		}
	}
	return cleared
}

// Version history shares the existing identity gate and its periodic sweep.
// Retain departed versions beyond the disconnect-cache and reset windows;
// live sessions and active faults also keep their gate through pruneLocked.
const identityVersionRetention = 20 * time.Minute

// Caller holds gate.mu. touched records both outcome activity and disconnect,
// so even a long-lived idle session receives a full reconnect grace window.
func (g *State) versionHistoryActive(now time.Time) bool {
	return g.version.Active(g.touched, now)
}
