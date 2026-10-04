package registry

import (
	"time"
)

// DrainQueuedRequestsForModel attempts to assign queued requests for a
// single model to available providers. Called when a load_model completes
// so requests don't have to wait for the next heartbeat cycle.
func (r *Registry) DrainQueuedRequestsForModel(model string) {
	r.DrainQueuedRequestsForModelWithReason(model, DrainTriggerUnknown)
}

// DrainQueuedRequestsForModelWithReason is DrainQueuedRequestsForModel with
// the bounded drain trigger (DrainTrigger* constants) the api layer knows at
// its call site — DrainTriggerLoad for a load_model success, for example — so
// the queued request's routing record names what unblocked it. Unknown values
// fold to DrainTriggerUnknown.
func (r *Registry) DrainQueuedRequestsForModelWithReason(model, reason string) {
	r.drainQueuedRequestsForModelsWithReason([]string{model}, reason)
}

// DrainQueuedRequestsForProviderWithReason attempts to assign queued requests
// for every model a provider serves. Called when a provider becomes newly
// eligible for routing (e.g. it just passed APNs code-identity attestation) so
// queued demand is satisfied immediately instead of waiting for the next
// heartbeat. reason is the bounded drain trigger the api layer knows at its
// call site (e.g. DrainTriggerChallenge after an attestation pass); unknown
// values fold to DrainTriggerUnknown.
func (r *Registry) DrainQueuedRequestsForProviderWithReason(p *Provider, reason string) {
	if p == nil {
		return
	}
	r.drainQueuedRequestsForModelsWithReason(providerModelIDs(p), reason)
}

// drainQueuedRequestsForModelsWithReason drains the per-model queues for
// models, stamping the bounded drain trigger (see DrainTrigger* constants) on
// every QueuedRequest whose routing decision this drain records, together with
// the request's enqueue position/depth, so the api layer can persist why and
// from where a queued request was dispatched.
func (r *Registry) drainQueuedRequestsForModelsWithReason(models []string, reason string) {
	reason = foldDrainTrigger(reason)
	queue, claims := r.queueConsumer()
	if queue == nil || len(models) == 0 {
		return
	}
	for _, model := range models {
		r.drainModelQueue(claims, model, reason)
	}
}

// drainModelQueue runs the drain pass for one model under the per-model claim
// (queue_drain_coalesce.go): a trigger that finds a pass in flight hands its
// reason to that pass and returns, and the pass reruns once for it after
// requeueing. A pass that does not complete releases the claim on the way out
// so a recovered panic cannot leave the model undrainable.
func (r *Registry) drainModelQueue(queue QueueClaims, model, reason string) {
	if !r.drainPasses.Begin(model, reason) {
		return
	}
	released := false
	defer func() {
		if !released {
			r.drainPasses.Abandon(model)
		}
	}()
	for {
		r.drainModelQueuePass(queue, model, reason)
		next, again := r.drainPasses.End(model)
		if !again {
			released = true
			return
		}
		reason = next
	}
}

// drainModelQueuePass pops every fresh queued request for model once and
// either assigns it, fails it deterministically, or requeues it in order.
// Fleet state is read live per scan; verdicts are reused within the pass only
// through the dominance skip, whose records this pass owns.
func (r *Registry) drainModelQueuePass(queue QueueClaims, model, reason string) {
	var skipped []*QueuedRequest
	// rejected anchors the per-pass dominance skip (queue_drain_dominance.go)
	// and deliberately survives requeueSkipped: an admission only removes
	// capacity, so this pass's verdicts stay valid for the requeued waiters
	// the next PopNextFresh hands back.
	var rejected []drainRejectionRecord
	admitted := 0
	saturated := false
	requeueSkipped := func() {
		for i := len(skipped) - 1; i >= 0; i-- {
			queue.RequeueFront(skipped[i])
		}
		skipped = nil
	}
	for {
		req := queue.PopNextFresh(model)
		if req == nil {
			requeueSkipped()
			break
		}
		if req.Pending == nil {
			req.Pending = &PendingRequest{
				RequestID:          req.RequestID,
				Model:              model,
				RequestedMaxTokens: defaultRequestedMaxTokens,
			}
		}
		// Queue time spends the same absolute first-content clock as
		// parsing, admission, and provider dispatch. Refresh immediately
		// before reservation so hard TTFT admission never reuses the
		// enqueue-time ceiling.
		if !req.Pending.RefreshFirstContentBudget(time.Now()) {
			req.failWithReason(ErrQueueFirstContentDeadline)
			continue
		}
		// A waiter at least as demanding as one this pass already rejected
		// purely on capacity/TTFT gets the same verdict from the same fleet
		// state; requeue it without paying for another full fleet scan.
		if drainDominated(req.Pending, rejected) {
			saturated = true
			skipped = append(skipped, req)
			continue
		}
		provider, decision := r.ReserveProviderEx(model, req.Pending)
		// Queue context for the routing record: where the request sat at
		// enqueue and which event ran the drain that produced this decision.
		decision.QueuePosition = req.EnqueuePosition
		decision.QueueDepth = req.DepthAtEnqueue
		decision.DrainTrigger = reason
		if provider == nil {
			if (req.Pending.Traits.RequiresToolConstraint || req.Pending.Traits.RequiresNativeMediaTools) &&
				!r.hasToolConstraintProviderForPending(model, req.Pending) {
				req.DrainTrigger = reason
				req.Decision = decision
				req.failWithReason(ErrQueueToolConstraintUnavailable)
				continue
			}
			// A pure-TTFT rejection (hard-reject mode, no capacity-rejected
			// provider that could free up) is deterministic for this pass:
			// requeueing would only make the waiter hang until maxWait for
			// the same answer. Fail it now; the API waiter turns
			// ErrQueueTTFTTooSlow into the standard ttft_too_slow 429 using
			// the decision's BestTTFTMs for Retry-After.
			if drainRejectionTTFTTerminal(req.Pending, decision) {
				req.DrainTrigger = reason
				req.Decision = decision
				req.failWithReason(ErrQueueTTFTTooSlow)
				continue
			}
			if rec, ok := drainRejectionRecordFor(req.Pending, decision); ok {
				rejected = append(rejected, rec)
			}
			saturated = saturated || drainPureCapacityRejection(decision)
			skipped = append(skipped, req)
			continue
		}
		admitted++
		req.DrainTrigger = reason
		req.Decision = decision
		requeueSkipped()

		releaseReservation := func() {
			provider.RemovePending(req.Pending.RequestID)
			r.SetProviderIdle(provider.ID)
		}
		assignment, offered := queue.PrepareProviderAssignment(req, provider, releaseReservation)
		if !offered {
			releaseReservation()
			continue
		}
		assignment.Publish()
	}
	// Heartbeat-triggered passes are suppressed for a short window after
	// a saturated pass (queue_drain_suppress.go); an admission proves
	// capacity moved and lifts the mark.
	switch {
	case admitted > 0:
		r.drainSuppress.Clear(model)
	case saturated:
		r.drainSuppress.MarkSaturated(model)
	}
}
