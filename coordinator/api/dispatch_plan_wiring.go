package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Routing v2 wave-2 dispatch wiring: the dispatchState half of the bounded
// plan (registry/dispatch_plan.go), the parallel capacity-probe round
// (registry/capacity_quotes.go), and the hedge governor/schedule
// (hedge_governor.go / hedge_schedule.go).
//
// Shape of the flow:
//
//	dispatchPrimary        — full scan retains the plan; after the primary
//	                         frame handoff, ONE probe round confirms/demotes
//	                         the alternates in parallel with the prompt.
//	waitFirstChunk         — may re-arm the speculative timer EARLIER when the
//	                         probe round proves the 50% point launches a backup
//	                         too late to win (hedgeLaunchAt).
//	runSpeculative         — the governor gates the launch; an admitted backup
//	                         consumes the plan before any rescan.
//	run (failover retries) — next attempts consume the plan before any rescan;
//	                         one RefreshDispatchPlan per logical request.
//
// Everything here degrades to the exact legacy behavior when the plan is
// empty/nil (legacy fleets, queue path, prefer-owner): no probes, the 50%
// launch point, full-scan selection.

// capacityProbeWindow bounds how long probed alternates get to answer before
// silence demotes them. 250ms (plan Phase 3): informational, never blocking —
// the primary is already in flight and the window is well inside the gap to
// the earliest useful hedge point on the ordinary 9s budget.
const capacityProbeWindow = 250 * time.Millisecond

// dispatchPlanProbeFanout sizes the collector's confidence map: a plan
// retains at most eight alternates (registry dispatchPlanMaxAlternates), so a
// probe round settles at most eight outcomes.
const dispatchPlanProbeFanout = 8

// noteProviderDispatched counts one inference frame actually handed to a
// provider. It is invoked from the write handoff callback — the same instant
// Timing.DispatchedAt is stamped — for the primary, queued, plan-retry, and
// speculative-backup sends alike. The deferred writer blocks the dispatching
// goroutine until the frame is handed off, so the increment happens-before
// every later read on the dispatch goroutine (the same publication discipline
// Timing.DispatchedAt relies on).
func (d *dispatchState) noteProviderDispatched() {
	d.providerDispatches++
}

// exhaustionAttemptCount is the machine count client-visible exhaustion
// messages and terminal logs report: actual provider dispatches when any
// frame reached a provider (plan Phase 3: "providerDispatches counts actual
// inference sends"), else the legacy loop count for requests that never
// dispatched (selection-only failures keep their historical "after 1
// attempt(s)" framing). Route rows keep the raw loop index unchanged.
func (d *dispatchState) exhaustionAttemptCount() int {
	if d.providerDispatches > 0 {
		return d.providerDispatches
	}
	return d.attempt + 1
}

// dispatchProviderWith runs the single prepare/encrypt/write funnel with a
// caller-chosen reserver, forwarding the request-shape inputs retained on
// dispatchState. timing is caller-supplied because the speculative backup
// deliberately shares only ReceivedAt with the primary's clock.
func (d *dispatchState) dispatchProviderWith(
	reserve dispatchReserver,
	timing *registry.RequestTiming,
	exclude map[string]struct{},
	recordRoute routeDecisionRecorder,
) (*registry.Provider, *registry.PendingRequest, registry.RoutingDecision, *registry.DispatchPlan, string, int) {
	return d.s.dispatchWithReserver(
		d.r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation,
		d.reservedMicroUSD, d.estimatedPromptTokens, d.deadline, d.requestedMaxTokens,
		d.tokenAdmission, d.requiresVision, d.traits(), d.allowedProviderSerials,
		d.isResponsesAPI, d.policy, timing, d.serviceReservation, d.cachePlan,
		exclude, d.attempt, recordRoute, d.noteProviderDispatched, reserve,
	)
}

// dispatchFromPlanMachinery consumes the retained plan for a retry or backup
// dispatch: the next revalidated plan entry first, then the request's single
// RefreshDispatchPlan. tried=false means the machinery yielded no reservation
// (plan nil/exhausted and the refresh spent or empty) and the caller must fall
// back to the legacy full scan — which preserves every existing terminal
// classification, because the plan path only changes WHERE the next provider
// comes from, never whether or why dispatch stops.
//
// When tried=true, the returned values carry dispatchOneProvider's exact
// semantics: a reserved provider whose funnel failed comes back nil with the
// funnel's error string/code, so the caller's failure handling is unchanged.
func (d *dispatchState) dispatchFromPlanMachinery(
	timing *registry.RequestTiming,
	exclude map[string]struct{},
	recordRoute routeDecisionRecorder,
) (provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision, lastErr string, lastErrCode int, tried bool) {
	plan := d.plan
	if plan == nil {
		return nil, nil, decision, "", 0, false
	}
	// 1) Next retained entry, re-verified against CURRENT state by
	// ReserveNextFromPlan (identity, full gate chain, atomic reservation).
	reserved := false
	provider, pr, decision, _, lastErr, lastErrCode = d.dispatchProviderWith(
		func(pending *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
			p, dec, _ := d.s.registry.ReserveNextFromPlan(pending, plan, excludeIDs...)
			reserved = p != nil
			return p, dec, nil
		},
		timing, exclude, recordRoute,
	)
	if reserved {
		return provider, pr, decision, lastErr, lastErrCode, true
	}
	// 2) The single full re-scan refresh. Latched on dispatchState (not just
	// the plan) so the retry loop and the speculative backup share ONE
	// refresh per logical request no matter how plans are threaded.
	if d.planRefreshUsed {
		return nil, nil, decision, "", 0, false
	}
	d.planRefreshUsed = true
	var fresh *registry.DispatchPlan
	provider, pr, decision, fresh, lastErr, lastErrCode = d.dispatchProviderWith(
		func(pending *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
			p, dec, freshPlan, performed := d.s.registry.RefreshDispatchPlan(pending, plan, excludeIDs...)
			if !performed {
				return nil, dec, nil
			}
			reserved = p != nil
			return p, dec, freshPlan
		},
		timing, exclude, recordRoute,
	)
	if fresh != nil {
		// The refreshed plan (born with its refresh consumed) replaces the
		// exhausted one so later retries/backups keep consuming entries.
		d.plan = fresh
	}
	if !reserved {
		return nil, nil, decision, "", 0, false
	}
	return provider, pr, decision, lastErr, lastErrCode, true
}

// maybeProbePlanCandidates launches the request's one capacity-probe round
// for the alternates retained by the primary reservation. Called strictly
// AFTER the primary frame handoff succeeded: probes run in parallel with the
// in-flight prompt and can never add primary latency (plan decision #1).
func (d *dispatchState) maybeProbePlanCandidates() {
	if d.probesLaunched || d.plan == nil || d.plan.Len() == 0 {
		return
	}
	// Prefer-owner and exclusive self-route requests are never probed against
	// the fleet (plan invariant): their backup rules are owner-scoped, so a
	// confirmed public alternate would have no consumer.
	if d.policy.enabled || d.policy.prefer {
		return
	}
	receivedAt := timingReceivedAt(d.timing)
	remaining, ok := d.firstTokenRemaining()
	if receivedAt.IsZero() || !ok || remaining <= 0 {
		// No request-absolute clock (legacy timing, unit fixtures): a refined
		// hedge instant could not be applied anyway — waitFirstChunk's re-arm
		// mirrors first_token_clock.go invariant 5 and needs ReceivedAt.
		return
	}
	d.probesLaunched = true
	d.hedgeAdvanceCh = make(chan time.Time, 1)
	outcomes := d.s.registry.ProbePlanCandidates(d.plan, registry.CapacityProbeShape{
		Model:             d.model,
		PromptTokens:      d.estimatedPromptTokens,
		MaxOutputTokens:   d.requestedMaxTokens,
		RequiresVision:    d.requiresVision,
		VisionImageCount:  d.visionImageCount,
		DeadlineRemaining: remaining,
	}, capacityProbeWindow)
	plan := d.plan
	advance := d.hedgeAdvanceCh
	deadline := d.deadline
	speculativeAt := d.speculativeAt
	saferun.Go(d.s.logger, "api.collectCapacityQuotes", func() {
		collectCapacityQuotes(outcomes, plan, receivedAt, deadline, speculativeAt, advance)
	})
}

// collectCapacityQuotes drains one probe round. The registry collector has
// already applied every outcome to the plan (ConfirmEntry/DemoteEntry happen
// BEFORE an outcome is readable — ProbePlanCandidates contract), so this
// consumer never re-applies them; it only extracts the hedge-timing
// refinement: when the settled round leaves a best confirmed backup whose
// HIGH-confidence quoted q90 proves the 50% point launches too late to win,
// the strictly earlier absolute launch instant is delivered on advance
// (buffered 1, non-blocking) for waitFirstChunk to re-arm against.
func collectCapacityQuotes(
	outcomes <-chan registry.QuoteOutcome,
	plan *registry.DispatchPlan,
	receivedAt time.Time,
	deadline time.Duration,
	speculativeAt time.Duration,
	advance chan<- time.Time,
) {
	// Confidence grades per answering provider: BestConfirmedBackup returns
	// identity + q90 but not the quote's provenance, and only a
	// high-confidence measured quote may move the launch point
	// (hedge_schedule.go invariant 1).
	confidences := make(map[string]hedgeQuoteConfidence, dispatchPlanProbeFanout)
	for outcome := range outcomes {
		if outcome.Quote != nil && outcome.Quote.AdmissibleNow {
			confidences[outcome.ProviderID] = quoteHedgeConfidence(outcome.Quote.Confidence)
		}
	}
	providerID, ttftP90, ok := plan.BestConfirmedBackup()
	if !ok {
		return
	}
	at := hedgeLaunchAt(receivedAt, deadline, ttftP90, confidences[providerID])
	if !at.Before(receivedAt.Add(speculativeAt)) {
		// Not strictly earlier than the armed point: nothing to refine
		// (hedgeLaunchOffset never schedules later than the 50% ceiling, and
		// speculativeAt stays the 50% default without a confirmed quote).
		return
	}
	select {
	case advance <- at:
	default:
	}
}

// quoteHedgeConfidence maps the wire confidence grade onto the hedge
// schedule's vocabulary. Unknown/absent grades collapse to none — only
// hedgeConfidenceHigh may move a launch earlier.
func quoteHedgeConfidence(confidence string) hedgeQuoteConfidence {
	switch confidence {
	case protocol.CapacityConfidenceHigh:
		return hedgeConfidenceHigh
	case protocol.CapacityConfidenceLow:
		return hedgeConfidenceLow
	}
	return hedgeConfidenceNone
}

// tryAcquireBackupHedge snapshots the registry-side inputs (idle alternative,
// model queue depth, fleet idle slots — advisory, RLock-only) and hands them
// to the governor's tryAcquireHedge, which applies the launch rules AND
// claims the global budget slot in one atomic operation. acquired hedges MUST
// be released exactly once via noteHedgeResolved (runSpeculative owns that).
//
// Two deliberate legacy escapes, per the dual-path decision (plan #3):
//   - A Server without a governor (bare test literals) keeps the legacy
//     always-hedge behavior rather than failing closed on a fixture gap.
//     Nothing is acquired: there is no counter to release.
//   - A capacity-SILENT fleet for the model (no provider reports a
//     BackendCapacity snapshot and none is quote-capable) makes every
//     governor input meaningless — (false, 0, 0) there is ignorance, not
//     saturation — so legacy providers keep today's unconditional 50% hedge
//     instead of losing insurance to a signal they cannot emit. The hedge is
//     still really in flight, so it acquires a slot ungoverned: capacity-
//     aware requests must see it against their budget.
func (d *dispatchState) tryAcquireBackupHedge(primaryID string) (hedgeVerdict, bool) {
	g := d.s.hedgeGov
	if g == nil {
		return hedgeAllow, false
	}
	exclude := append(d.excludedProviderIDs(), primaryID)
	idleAlt, queueDepth, fleetIdle, capacitySignals := d.s.registry.HedgeGovernorSnapshot(d.model, d.pr, exclude...)
	if !capacitySignals {
		g.acquireHedgeUngoverned()
		return hedgeAllow, true
	}
	return g.tryAcquireHedge(d.model, hedgeGovernorInputs{
		idleAlternativeExists: idleAlt,
		modelQueueDepth:       queueDepth,
		fleetIdleSlots:        fleetIdle,
	})
}
