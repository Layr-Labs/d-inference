package registry

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/dispatchplan"
)

// CapacityProbeShape carries request shape; the owner buckets token counts
// before sending the existing protocol.CapacityProbeMessage.
type CapacityProbeShape = dispatchplan.ProbeShape

// QuoteOutcome is published only after the owner settles its plan entry.
type QuoteOutcome = dispatchplan.QuoteOutcome

// capacityQuoteReady reports whether this connection has proven the wave-2
// capacity protocol: a heartbeat on THIS connection carried capacity_seq > 0
// (see the gate in Heartbeat). Legacy sessions are never probed — a frame
// type they do not implement would at best be ignored and at worst kill the
// connection, and their plan entries stay ledger-scored mid-tier by design
// (dual path until the fleet floor).
func (p *Provider) capacityQuoteReady() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.capacityQuoteCapable
}

// HandleCapacityQuote correlates a reply to the bound provider and preserves
// the original bounded drop reasons after the owner's leaf lock is released.
func (r *Registry) HandleCapacityQuote(providerID string, msg *protocol.CapacityQuoteMessage) {
	if msg == nil || msg.QuoteID == "" {
		return
	}
	reason := r.capacityQuotes.Handle(providerID, msg)
	switch reason {
	case dispatchplan.QuoteUnknown:
		r.logger.Debug("dropping capacity quote", "reason", "unknown_or_late_quote_id", "provider_id", providerID)
	case dispatchplan.QuoteProviderMismatch:
		r.logger.Warn("dropping capacity quote", "reason", "provider_mismatch", "provider_id", providerID)
	case dispatchplan.QuoteExpired:
		r.logger.Debug("dropping capacity quote", "reason", "expired", "provider_id", providerID)
	}
}

// ProbePlanCandidates binds exact retained connections to the data writer.
// The owner confirms or demotes entries before publishing buffered outcomes;
// legacy capability, timeout and send-failure behavior is unchanged.
func (r *Registry) ProbePlanCandidates(plan *DispatchPlan, shape CapacityProbeShape, window time.Duration) <-chan QuoteOutcome {
	var probes *dispatchplan.Probes[*Provider]
	if r != nil {
		probes = &r.capacityQuotes
	}
	return probes.Probe(plan.owned(), shape, window, dispatchplan.Transport[*Provider]{
		Ready:  (*Provider).capacityQuoteReady,
		Write:  (*Provider).WriteText,
		Logger: func() *slog.Logger { return r.logger },
	})
}
