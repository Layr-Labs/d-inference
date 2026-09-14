package registry

import "errors"

// ErrQueueTTFTTooSlow is returned when the queue drain determines the waiter is
// deterministically unservable: every provider that could otherwise serve the
// model fails ONLY the per-request TTFT ceiling (pr.MaxTTFTMs, hard-reject
// mode). Waiting out maxWait cannot change that verdict within the pass, so the
// waiter is failed immediately and the API layer writes the standard
// ttft_too_slow 429 instead of a queue timeout.
var ErrQueueTTFTTooSlow = errors.New("all providers for queued request exceed the TTFT target")

// ErrQueueFirstContentDeadline is returned when the request-absolute
// first-content clock expires while waiting in the coordinator queue.
var ErrQueueFirstContentDeadline = errors.New("queued request first-content deadline expired")

// ErrQueueToolConstraintUnavailable is returned when a constrained waiter can
// no longer be served by any explicit-capability provider. Old providers may
// still serve auto/ordinary requests, but required/named/none never downgrade.
var ErrQueueToolConstraintUnavailable = errors.New(
	"no provider supports inference-time tool constraints for queued request")

// Bounded drain triggers: the event that ran the queue drain which reserved a
// queued request. Recorded on QueuedRequest.DrainTrigger and
// RoutingDecision.DrainTrigger for the system-profiler routing record. Closed
// vocabulary — foldDrainTrigger maps anything else to DrainTriggerUnknown.
const (
	DrainTriggerHeartbeat  = "heartbeat"  // Registry.Heartbeat (a heartbeat may make a slot routable)
	DrainTriggerIdle       = "idle"       // SetProviderIdle (a provider finished a job)
	DrainTriggerChallenge  = "challenge"  // RecordChallengeSuccess / DrainQueuedRequestsForProvider
	DrainTriggerLoad       = "load"       // load_model success (DrainQueuedRequestsForModel)
	DrainTriggerDisconnect = "disconnect" // Disconnect (re-run so unservable waiters fail fast)
	DrainTriggerKick       = "kick"       // cold-dispatch kick from the api layer
	DrainTriggerUnknown    = "unknown"    // legacy caller that has not been migrated
)

// foldDrainTrigger returns reason if it is one of the bounded DrainTrigger*
// values, else DrainTriggerUnknown. Constant strings only — no allocation.
func foldDrainTrigger(reason string) string {
	switch reason {
	case DrainTriggerHeartbeat, DrainTriggerIdle, DrainTriggerChallenge, DrainTriggerLoad,
		DrainTriggerDisconnect, DrainTriggerKick:
		return reason
	default:
		return DrainTriggerUnknown
	}
}

// drainRejectionTTFTTerminal reports whether a drain-time reservation failure
// is a PURE TTFT rejection — deterministic for this pass, so the waiter should
// be failed with ErrQueueTTFTTooSlow instead of hanging until maxWait:
//   - at least one provider was rejected only by the per-request TTFT ceiling
//     (TTFTRejections > 0 requires pr.MaxTTFTMs > 0, i.e. hard-reject mode);
//   - no provider was capacity-rejected: a busy fast provider freeing up could
//     still serve the request, so mixed rejections keep waiting;
//   - no candidate passed the scan: CandidateCount > 0 with a nil provider is
//     the transient admit re-check race, not unservability.
//
// Owner-scoped waiters are never TTFT-failed on the public-fleet verdict
// (mirrors FailQueuedRequestsForModel's preservation semantics). Their queue
// ceiling is already 0 (queueMaxTTFTMs), so they cannot produce TTFT
// rejections; the explicit guard keeps the invariant even if that wiring
// changes.
func drainRejectionTTFTTerminal(pr *PendingRequest, decision RoutingDecision) bool {
	if pr == nil || pr.SelfRouteOnly || pr.PreferOwner {
		return false
	}
	return decision.TTFTRejections > 0 &&
		decision.CapacityRejections == 0 &&
		decision.CandidateCount == 0
}

// CompetingQueueDepth counts the queued waiters for a model whose routing
// constraints could overlap the capacity available to pr — the hedge
// governor's "queued consumers outrank insurance" input. A raw QueueSize
// over-suppresses: a waiter that structurally CANNOT drain onto the pool a
// hedge for pr would consume is not a competing consumer, and counting it
// starves every public request of hedges for the waiter's whole queue stay
// (codex P2). Excluded:
//
//   - exclusive self-route waiters (Pending.SelfRouteOnly): they drain only
//     onto their owner's machines and never fall back to the public fleet,
//     so public capacity spent on a hedge takes nothing from them;
//   - serial-pinned waiters (Pending.AllowedProviderSerials) whose allowlist
//     does not intersect pr's own: they can only consume their pinned
//     providers. When pr is itself pinned to an overlapping set the two
//     demonstrably compete for the same pool and the waiter counts.
//
// A waiter with a nil Pending has an unconstrained shape and counts
// conservatively. pr == nil means "no constraint context": only the
// structural self-route/serial-pinned exclusions apply.
func (q *RequestQueue) CompetingQueueDepth(model string, pr *PendingRequest) int {
	depth := 0
	q.queue.Visit(model, func(req *QueuedRequest) {
		w := req.Pending
		if w == nil {
			depth++
			return
		}
		if w.SelfRouteOnly {
			return
		}
		if len(w.AllowedProviderSerials) > 0 &&
			(pr == nil || !serialSetsIntersect(w.AllowedProviderSerials, pr.AllowedProviderSerials)) {
			return
		}
		depth++
	})
	return depth
}

// serialSetsIntersect reports whether two attested-serial allowlists share a
// serial. Sized for the tiny per-request lists routing carries; no map.
func serialSetsIntersect(a, b []string) bool {
	for _, s := range a {
		for _, t := range b {
			if s == t && s != "" {
				return true
			}
		}
	}
	return false
}

// PreferWaiterOwners returns the distinct owner account IDs of PreferOwner
// waiters currently queued for a model. Used by RejectUnservableQueuedRequests
// to compute owner eligibility OUTSIDE the queue lock (OwnedProviderSummary
// takes the registry lock), avoiding any q.mu→r.mu nesting.
func (q *RequestQueue) PreferWaiterOwners(model string) []string {
	seen := make(map[string]struct{})
	var owners []string
	q.queue.Visit(model, func(req *QueuedRequest) {
		if req.Pending != nil && req.Pending.PreferOwner && req.Pending.OwnerAccountID != "" {
			if _, ok := seen[req.Pending.OwnerAccountID]; !ok {
				seen[req.Pending.OwnerAccountID] = struct{}{}
				owners = append(owners, req.Pending.OwnerAccountID)
			}
		}
	})
	return owners
}

// FailQueuedRequestsForModel rejects queued requests for a model by sending nil
// on their ResponseCh. Waiters receive ErrQueueTimeout. Called when the
// coordinator determines no provider can serve the model (e.g. all load_model
// attempts failed with no alternative provider).
//
// Owner-scoped waiters are preserved because this verdict comes from a PUBLIC
// capacity check, which ignores the caller's own machine:
//   - Exclusive self-route (Pending.SelfRouteOnly) is ALWAYS preserved — it only
//     queues after the preflight confirmed the owner has an online machine, so
//     its own (busy) machine may free up; it never falls back to public.
//   - Prefer (Pending.PreferOwner) is preserved ONLY when preferOwnerEligible
//     says the owner currently has an owned provider serving the model (it may
//     free up). A prefer waiter with NO owned provider is effectively a public
//     request, so it is failed fast like any other public waiter rather than
//     left to hit the 120s stale timeout.
//
// Preserved waiters drain on availability or hit their own maxWait timer in
// WaitForProviderContext (surfacing machine_busy); entries they leave behind
// are swept lazily by cleanStaleLocked on the next Enqueue or QueuedModels
// scan. Returns the number of requests failed.
func (q *RequestQueue) FailQueuedRequestsForModel(model string, preferOwnerEligible map[string]bool) int {
	return q.queue.FailUnless(model, func(req *QueuedRequest) bool {
		p := req.Pending
		return p != nil && (p.SelfRouteOnly || p.PreferOwner && preferOwnerEligible[p.OwnerAccountID])
	}, (*QueuedRequest).expireFromQueue)
}
