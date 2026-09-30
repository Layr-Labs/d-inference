package api

import (
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const predictiveRefusalRefreshThreshold = 2

func firstContentDeadlineAt(receivedAt time.Time, deadline time.Duration) time.Time {
	if receivedAt.IsZero() || deadline <= 0 {
		return time.Time{}
	}
	return receivedAt.Add(deadline)
}

// configureFirstContentReservation runs before every reserve, including plan
// retries and hedges. These fields affect service predictions only; physical
// token reservations and billing keep their existing prompt/output inputs.
func (d *dispatchState) configureFirstContentReservation(pr *registry.PendingRequest, hedge bool) {
	pr.FirstContentPromptTokens = calibratedContextPromptTokens(d.model, d.estimatedPromptTokens)
	pr.RequireFreshFeasible = d.predictiveRefusals >= predictiveRefusalRefreshThreshold
	pr.RequireFreshFeasibleAfter = d.freshFeasibleAfter
	pr.Hedge = hedge
	if (hedge || pr.RequireFreshFeasible) && d.deadline <= 0 {
		pr.FirstContentPlanningHorizon = inferenceTimeout
	}
}

func (d *dispatchState) firstContentPromptWork() int {
	// A quote can outlive planner-generation validity. Cover both the exact
	// current plan and the calibrated fallback so invalidation cannot turn
	// an undersized probe into evidence for a larger request at commit.
	tokens := max(d.cachePlan.PromptTokenCount, calibratedContextPromptTokens(d.model, d.estimatedPromptTokens))
	if d.r != nil {
		if work := promptwork.FromContext(d.r.Context(), d.model, d.rawBody); work != nil && work.IsQualifiedFor(work.ModelArtifactHash, work.PromptContractID) {
			tokens = max(tokens, work.UpperBoundTokens)
		}
	}
	return tokens
}

func (d *dispatchState) notePredictiveRefusal(provider *registry.Provider) {
	if provider != nil {
		if d.predictiveRefusedProviders == nil {
			d.predictiveRefusedProviders = make(map[string]struct{})
		}
		if _, seen := d.predictiveRefusedProviders[provider.ID]; seen {
			return
		}
		d.predictiveRefusedProviders[provider.ID] = struct{}{}
		if d.excludeProviders == nil {
			d.excludeProviders = make(map[string]struct{})
		}
		d.excludeProviders[provider.ID] = struct{}{}
	}
	d.predictiveRefusals++
	if d.predictiveRefusals >= predictiveRefusalRefreshThreshold {
		d.freshFeasibleAfter = time.Now()
	}
}

// refreshPredictiveRefusalQuotes buys at most one bounded evidence refresh.
// Wait for the earlier advisory round to finish before starting another, so
// concurrent fanout never exceeds two. Both waits spend the original clock.
// Missing/negative quotes do not authorize a third speculative dispatch: the
// reservation gate still requires fresh feasible evidence.
func (d *dispatchState) refreshPredictiveRefusalQuotes() {
	if d.predictiveRefusals < predictiveRefusalRefreshThreshold || d.freshQuotesUsed || d.plan == nil {
		return
	}
	d.freshQuotesUsed = true
	ctx, cancel := firstTokenWriteContext(d.r.Context(), timingReceivedAt(d.timing), d.deadline)
	defer cancel()
	if d.probeDone != nil {
		select {
		case <-d.probeDone:
		case <-ctx.Done():
			return
		}
	}
	remaining, ok := d.firstTokenRemaining()
	if d.deadline <= 0 {
		remaining, ok = inferenceTimeout, true
	}
	if !ok || remaining <= 0 || ctx.Err() != nil {
		return
	}
	outcomes := d.s.registry.ProbePlanCandidates(d.plan, registry.CapacityProbeShape{
		Model:                d.model,
		PromptTokens:         d.firstContentPromptWork(),
		MaxOutputTokens:      d.requestedMaxTokens,
		RequiresVision:       d.requiresVision,
		VisionImageCount:     d.visionImageCount,
		DeadlineRemaining:    remaining,
		FirstContentDeadline: firstContentDeadlineAt(timingReceivedAt(d.timing), d.deadline),
		RefreshEvidence:      true,
		ExcludedProviderIDs:  d.excludedProviderIDs(),
	}, min(capacityProbeWindow, remaining))
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

// Current wire telemetry reports occupancy and work, but no credible future
// release time for a full provider. A configured maximum wait cannot establish
// that a queued public request will still deliver content before its deadline.
// Owner-directed and intentionally deadline-exempt requests keep their policy.
func (d *dispatchState) rejectUnforecastableCapacityWait(decision registry.RoutingDecision) bool {
	if d.deadline <= 0 || d.policy.enabled || d.policy.prefer {
		return false
	}
	code, reason := http.StatusTooManyRequests, "machine_busy"
	errType, message := "rate_limit_exceeded", fmt.Sprintf("all providers for model %q are at capacity", d.publicModel)
	if decision.CapacityRejections == 0 && decision.CandidateCount == 0 {
		code, reason = http.StatusServiceUnavailable, "no_provider"
		errType, message = "provider_error", fmt.Sprintf("no provider available for model %q", d.publicModel)
	}
	d.s.registry.RecordWarmPoolCapacityReject(d.model)
	d.s.triggerWarmPool()
	retryAfter := d.s.estimateRetryAfter(d.model)
	d.refundReservation()
	d.preContentTerminal(d.rejectionInfoWithDecision("dispatch", reason, code, retryAfter*1000, decision), retryAfter, errType, message, errType)
	return true
}
