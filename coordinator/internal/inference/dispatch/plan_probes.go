package dispatch

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

const capacityProbeWindow = 250 * time.Millisecond
const dispatchPlanProbeFanout = 2

type ProbeInput struct {
	Model        string
	PromptTokens int
	// PromptWork is resolved only after the probe guards and any prior round.
	PromptWork       func() int
	MaxOutputTokens  int
	RequiresVision   bool
	VisionImageCount int
	ReceivedAt       time.Time
	Deadline         time.Duration
	SpeculativeAt    time.Duration
	Scope            Scope
}

func (in ProbeInput) remaining() (time.Duration, bool) {
	if in.Deadline <= 0 {
		return firstcontent.ExemptPlanningHorizon, true
	}
	return firstcontent.NewClock(in.ReceivedAt, in.Deadline, in.SpeculativeAt).Remaining()
}

func (in ProbeInput) shape(remaining time.Duration) registry.CapacityProbeShape {
	promptTokens := in.PromptTokens
	if in.PromptWork != nil {
		promptTokens = in.PromptWork()
	}
	return registry.CapacityProbeShape{
		Model: in.Model, PromptTokens: promptTokens, MaxOutputTokens: in.MaxOutputTokens,
		RequiresVision: in.RequiresVision, VisionImageCount: in.VisionImageCount,
		DeadlineRemaining:    remaining,
		FirstContentDeadline: firstcontent.FirstContentDeadlineAt(in.ReceivedAt, in.Deadline),
	}
}

// Probe is called after primary handoff, so advisory quotes add no primary
// latency. Deadline exemptions preserve probes without creating an SLA timer.
func (p *Plan) Probe(in ProbeInput) (<-chan time.Time, bool) {
	if p.probesLaunched || p.plan == nil || p.plan.Len() == 0 || in.Scope.SelfRouteOnly || in.Scope.PreferOwner {
		return nil, false
	}
	remaining, ok := in.remaining()
	if in.ReceivedAt.IsZero() || !ok || remaining <= 0 {
		return nil, false
	}
	p.probesLaunched = true
	advance := make(chan time.Time, 1)
	outcomes := p.dispatcher.registry.ProbePlanCandidates(p.plan, in.shape(remaining), capacityProbeWindow)
	plan := p.plan
	receivedAt, deadline, speculativeAt := in.ReceivedAt, in.Deadline, in.SpeculativeAt
	done := make(chan struct{})
	p.probeDone = done
	saferun.Go(p.dispatcher.logger, "api.collectCapacityQuotes", func() {
		defer close(done)
		CollectCapacityQuotes(outcomes, plan, receivedAt, deadline, speculativeAt, advance)
	})
	return advance, true
}

// RefreshQuotes waits for the initial round before starting the one bounded
// evidence refresh. Both waits spend the original request budget.
func (p *Plan) RefreshQuotes(r *http.Request, in ProbeInput, refusals int, excluded []string) {
	if refusals < firstcontent.RefusalRefreshThreshold || p.freshQuotesUsed || p.plan == nil {
		return
	}
	p.freshQuotesUsed = true
	ctx, cancel := firstcontent.FirstTokenWriteContext(r.Context(), in.ReceivedAt, in.Deadline)
	defer cancel()
	if p.probeDone != nil {
		select {
		case <-p.probeDone:
		case <-ctx.Done():
			return
		}
	}
	remaining, ok := in.remaining()
	if !ok || remaining <= 0 || ctx.Err() != nil {
		return
	}
	shape := in.shape(remaining)
	shape.RefreshEvidence = true
	shape.ExcludedProviderIDs = excluded
	outcomes := p.dispatcher.registry.ProbePlanCandidates(p.plan, shape, min(capacityProbeWindow, remaining))
	for {
		select {
		case _, open := <-outcomes:
			if !open {
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

// CollectCapacityQuotes consumes a round already applied by the registry. Only
// a high-confidence quote may advance the hedge, and never past its armed time.
func CollectCapacityQuotes(outcomes <-chan registry.QuoteOutcome, plan *registry.DispatchPlan, receivedAt time.Time, deadline, speculativeAt time.Duration, advance chan<- time.Time) {
	confidences := make(map[string]hedge.QuoteConfidence, dispatchPlanProbeFanout)
	for outcome := range outcomes {
		if outcome.Quote != nil && outcome.Quote.AdmissibleNow {
			confidences[outcome.ProviderID] = quoteHedgeConfidence(outcome.Quote.Confidence)
		}
	}
	if deadline <= 0 {
		return
	}
	providerID, ttftP90, ok := plan.BestConfirmedBackup()
	if !ok {
		return
	}
	at := hedge.LaunchAt(receivedAt, deadline, ttftP90, confidences[providerID])
	if !at.Before(receivedAt.Add(speculativeAt)) {
		return
	}
	select {
	case advance <- at:
	default:
	}
}

func quoteHedgeConfidence(confidence string) hedge.QuoteConfidence {
	switch confidence {
	case protocol.CapacityConfidenceHigh:
		return hedge.ConfidenceHigh
	case protocol.CapacityConfidenceLow:
		return hedge.ConfidenceLow
	}
	return hedge.ConfidenceNone
}
