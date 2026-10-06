package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// An advertised exact profile is the producer's proof of its reviewed power
// policy and stable observation window. Missing live posture is not nominal.
func deadlineNominalPosture(capacity *protocol.BackendCapacity, metrics protocol.SystemMetrics) bool {
	return deadline.NominalPosture(capacity, metrics)
}

// Unknown activity cannot establish quiescence. This checks every slot, even
// models outside the coordinator's catalog, because the evidence is Mac-wide.
func deadlineReportedQuiescent(capacity *protocol.BackendCapacity) bool {
	return deadline.ReportedQuiescent(capacity)
}

func (p *Provider) recordDeadlineActivityLocked(now time.Time) {
	p.deadlinePostureLocked().Activity(now)
}

// Called only for an accepted heartbeat. Sequence rejection must not change
// either clock. These clocks record invalidation, never evidence of retirement.
func (p *Provider) reconcileDeadlineApplicabilityLocked(capacity *protocol.BackendCapacity, metrics protocol.SystemMetrics, now time.Time) {
	if !deadlineReportedQuiescent(capacity) {
		p.recordDeadlineActivityLocked(now)
	}
	if !deadlineNominalPosture(capacity, metrics) {
		p.deadlinePostureLocked().InvalidatePosture(now)
	}
}

// Caller holds r.mu and p.mu. Provider proof cannot override intervening local
// work, including a terminal whose real engine retirement is still outstanding.
func (r *Registry) deadlineProfileApplicableLocked(p *Provider, profile *deadlinePerformanceProfile, now time.Time) bool {
	return (&ProviderEligibility{registry: r}).deadlineApplicableLocked(p, (*deadline.Profile)(profile), now)
}

func (e *ProviderEligibility) deadlineApplicableLocked(p *Provider, profile *deadline.Profile, now time.Time) bool {
	r := e.registry
	if profile == nil {
		return false
	}
	quiet := len(p.pendingReqs) == 0 && p.serviceRetirement.Account(nil).Retiring == 0 &&
		!r.providerHasPendingLoad(p.ID) && !providerAutopilotTransitionLocked(p) && deadlineReportedQuiescent(p.BackendCapacity)
	return p.deadlinePostureLocked().Allows(profile, quiet, now)
}

// Registry-only load mutations use the normal r.mu -> p.mu lock order.
func (r *Registry) recordDeadlineLoadActivityLocked(providerID string, now time.Time) {
	if p := r.providers[providerID]; p != nil {
		p.mu.Lock()
		p.recordDeadlineActivityLocked(now)
		p.mu.Unlock()
	}
}
