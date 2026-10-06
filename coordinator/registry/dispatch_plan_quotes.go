package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityquote"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A missing dispatch plan retains the original empty quote-owner semantics.
func (p *DispatchPlan) quoteOwner() *QuotePlan {
	if p == nil {
		return nil
	}
	return p.QuotePlan
}

func (p *DispatchPlan) Len() int                    { return p.quoteOwner().Len() }
func (p *DispatchPlan) Remaining() int              { return p.quoteOwner().Remaining() }
func (p *DispatchPlan) PeekNext() (PlanEntry, bool) { return p.quoteOwner().PeekNext() }
func (p *DispatchPlan) ConfirmEntry(id string, quote *protocol.CapacityQuoteMessage) {
	p.quoteOwner().ConfirmEntry(id, quote)
}
func (p *DispatchPlan) DemoteEntry(id string) { p.quoteOwner().DemoteEntry(id) }
func (p *DispatchPlan) BestConfirmedBackup() (string, time.Duration, bool) {
	return p.quoteOwner().BestConfirmedBackup()
}
func (p *DispatchPlan) probeTargets() []planEntry        { return p.quoteOwner().probeTargets() }
func (p *DispatchPlan) refreshProbeTargets() []planEntry { return p.quoteOwner().refreshProbeTargets() }
func (p *DispatchPlan) ApplyQuoteDelivery(d capacityquote.Delivery) QuoteOutcome {
	return p.quoteOwner().ApplyQuoteDelivery(d)
}
