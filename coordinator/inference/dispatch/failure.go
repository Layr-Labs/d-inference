package dispatch

import (
	"net/http"
	"strconv"

	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (d *execution) setLastError(errText string, statusCode int) {
	d.lastErr = errText
	d.lastErrCode = statusCode
	d.lastErrReason = ""
	// Not a provider capacity rejection (timeout / no-provider / coordinator
	// fault): clear any budget captured from a prior attempt so it never bleeds
	// into a later classification.
	d.lastErrProviderBudget = 0
	d.lastErrRejectionReason = ""
	// Same bleed-through rule for the typed terminal fields: a coordinator-
	// synthesized error is not a provider terminal, so a stale typed cause from
	// a prior attempt must not reclassify it (shouldStopFailover trusts a typed
	// admission_timeout as transient capacity) and stale usage must not land on
	// its route row. An empty cause here is also what lets the wait loops'
	// 504 branches tell a synthetic timeout from a typed provider 504.
	d.lastErrTerminalCause = ""
	d.lastErrCoordinatorCause = ""
	d.lastErrAttemptUsage = nil
	d.lastErrFeasibleAfterMS = 0
	d.lastFailureDeadline = false
}

func isGenuinePreContentFault(
	msg protocol.InferenceErrorMessage,
	providerBudget int64,
	modelContext int,
) bool {
	if msg.StatusCode < http.StatusInternalServerError {
		return false
	}
	if attemptpolicy.IsProviderHealthNeutralErrorReason(msg.ErrorReason) {
		return false
	}
	switch msg.FailureCode {
	case protocol.FailureCodeInvalidRequest,
		protocol.FailureCodeInvalidMedia,
		protocol.FailureCodeMediaTooLarge,
		protocol.FailureCodeUnsupportedMedia,
		protocol.FailureCodeTemplateRender,
		protocol.FailureCodeModelUnavailable,
		protocol.FailureCodeCapacity,
		protocol.FailureCodeCancelled:
		return false
	}
	switch class, _ := attemptpolicy.ClassifyTerminalCause(msg.TerminalCause); class {
	case attemptpolicy.CauseClassNeutral, attemptpolicy.CauseClassCapacity:
		return false
	case attemptpolicy.CauseClassFault:
		return true
	}
	return attemptpolicy.ClassifyRejection(
		msg.ErrorReason, msg.Error, providerBudget, modelContext,
		msg.RejectionReason,
	) == attemptpolicy.RejectionNotCapacity
}

func terminalFailureFromMessage(msg protocol.InferenceErrorMessage) dispatchTerminalFailure {
	return dispatchTerminalFailure{
		errText:       msg.Error,
		statusCode:    msg.StatusCode,
		terminalCause: msg.TerminalCause,
		deadline:      attemptpolicy.IsDeadlineUnreachableErrorReason(msg.ErrorReason),
	}
}

func (d *execution) captureGenuineFault(
	provider *registry.Provider,
	msg protocol.InferenceErrorMessage,
	providerBudget int64,
) {
	if !isGenuinePreContentFault(msg, providerBudget, d.modelMaxContext) {
		return
	}
	fault := terminalFailureFromMessage(msg)
	fault.attribution = d.providerSlotAttribution(provider, d.model)
	d.genuineFault = &fault
}

func (d *execution) currentTerminalFailure() dispatchTerminalFailure {
	return dispatchTerminalFailure{
		errText:       d.lastErr,
		statusCode:    d.lastErrCode,
		terminalCause: d.lastErrTerminalCause,
		deadline:      d.lastFailureDeadline,
	}
}

func (d *execution) terminalFailureForExhaustion() (
	dispatchTerminalFailure,
	bool,
) {
	if d.genuineFault != nil && !d.terminalClientError {
		return *d.genuineFault, true
	}
	return d.currentTerminalFailure(), false
}

// classifyExhaustedStatus preserves provider-attempt telemetry while mapping a
// coordinator-synthesized pre-content timeout to the retryable status exposed to
// the caller. A typed provider 504 (safety deadline / backpressure timeout) is a
// real provider terminal and must remain 504; an untyped 504 is the dispatch
// loop's existing discriminator for its own first-content timeout.
func classifyExhaustedStatus(statusCode int, terminalCause string) (code int, reason string, reclassified bool) {
	if statusCode == http.StatusGatewayTimeout && !attemptpolicy.IsTypedTimeout504Cause(terminalCause) {
		return http.StatusTooManyRequests, "first_chunk_timeout", true
	}
	return statusCode, "dispatch_exhausted", false
}

type exhaustedDominance int

const (
	exhaustedUndecided exhaustedDominance = iota
	exhaustedClientError
	exhaustedGenuineFault
	exhaustedUnservable
	exhaustedDeadline
)

func (d *execution) resolveDominantExhaustedStatus(
	failure dispatchTerminalFailure,
	stickyFault bool,
) (statusCode int, reason string, timeoutReclassified bool, dominance exhaustedDominance) {
	statusCode, reason, timeoutReclassified = classifyExhaustedStatus(
		failure.statusCode, failure.terminalCause)
	if timeoutReclassified && failure.errText == errQueueDeadlineExpired {
		// Never dispatched: the synthetic timeout came from the queue wait.
		reason = RejectionReasonQueueDeadline
	}
	switch {
	case d.terminalClientError:
		statusCode = d.terminalClientErrorCode
		reason = "client_error"
		if d.terminalClientErrorReason != "" {
			reason = d.terminalClientErrorReason
		}
		return statusCode, reason, timeoutReclassified, exhaustedClientError
	case stickyFault:
		return statusCode, reason, timeoutReclassified, exhaustedGenuineFault
	case d.unservable:
		statusCode = http.StatusTooManyRequests
		reason = d.unservableReason
		if reason == "" {
			reason = rejectionReasonOversized
		}
		return statusCode, reason, timeoutReclassified, exhaustedUnservable
	case failure.deadline:
		return http.StatusTooManyRequests, rejectionReasonDeadlineUnreachable,
			timeoutReclassified, exhaustedDeadline
	default:
		return statusCode, reason, timeoutReclassified, exhaustedUndecided
	}
}

// setLastInferenceError records a pre-content provider rejection as the dispatch
// loop's last error and snapshots the rejecting provider's reported token budget
// for d.model. shouldStopFailover needs that budget to tell a fleet-wide
// DETERMINISTIC context overflow apart from THIS node's memory-pressured KV budget
// (see classifyRejection). provider may be nil (budget 0 = unknown).
func (d *execution) setLastInferenceError(provider *registry.Provider, msg protocol.InferenceErrorMessage) {
	msg = attemptpolicy.NormalizeInferenceErrorForInternalUse(msg)
	providerBudget := providerReportedBudget(provider, d.model)
	if msg.AvailableTokenBudget != nil {
		// Enriched rejection (routing v2): the LIVE gate budget at rejection
		// time beats the last heartbeat's snapshot — this closes the
		// documented stale-snapshot LIMITATION in classifyRejection, where a
		// budget that shrank below the model context between heartbeats
		// misclassified a node-pressured reject as fleet-deterministic. The
		// wire field is a pointer precisely so an EXPLICIT zero survives:
		// it means "this node has no headroom RIGHT NOW" (maximally
		// transient, budget frees as sequences retire), never "unknown".
		providerBudget = *msg.AvailableTokenBudget
	}
	d.lastErr = msg.Error
	d.lastErrCode = msg.StatusCode
	d.lastErrReason = msg.ErrorReason
	d.lastFailureDeadline = attemptpolicy.IsDeadlineUnreachableErrorReason(msg.ErrorReason)
	d.lastErrProviderBudget = providerBudget
	d.lastErrRejectionReason = msg.RejectionReason
	d.lastErrTerminalCause = msg.TerminalCause
	d.lastErrCoordinatorCause = msg.CoordinatorCause
	d.lastErrAttemptUsage = msg.AttemptUsage
	d.lastErrFeasibleAfterMS = msg.FeasibleAfterMS
	d.captureGenuineFault(provider, msg, providerBudget)
}

// providerReportedBudget reads a provider's reported token budget for a model,
// tolerating a nil provider (returns 0 = unknown).
func providerReportedBudget(provider *registry.Provider, model string) int64 {
	if provider == nil {
		return 0
	}
	return provider.ReportedTokenBudgetMaxForModel(model)
}

// noteDispatchRetry feeds the inference-error breaker + refund for a pre-commit
// provider error and, unless held boilerplate was discarded (which emits its own
// pre-content failover counter), emits the generic retry counter. This is the
// exact `if !d.noteProviderError(...) { s.deps.Counters.Incr(retry) }` pattern.
func (d *execution) noteDispatchRetry(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string, causes ...protocol.CoordinatorInferenceErrorCause) {
	if !d.noteProviderError(provider, pr, statusCode, errStr, errReason, terminalCause, held, causes...) {
		d.s.deps.Counters.Incr("inference.dispatches", []string{"status:retry"})
	}
}

// noteProviderError is the dispatch loop's single funnel into
// noteDispatchProviderError. When the structured error_reason is health-neutral
// (isProviderHealthNeutralErrorReason: jinja_* template-render failures,
// tool_noncompliance, or deadline_unreachable), the provider is withheld so
// none of the provider-fault trackers fed by noteInferenceError — the
// shape-keyed inference-error breaker, the per-provider node-health breaker,
// the stable-identity ejection breaker, and the capacity-reject cooldown —
// records the terminal. A jinja_* failure arrives as a raw provider 500,
// exactly the sickness shape all three breakers count, so without this gate
// a few malformed tool histories could quarantine healthy providers/pairs
// before the E4 relabel ever runs (the relabel happens later, in
// shouldStopFailover / the route-outcome writers); tool_noncompliance 422s
// are code-neutral in every breaker today, but gating them here keeps the
// reason vocabulary in lockstep with the reputation exemption in
// handleInferenceError.
//
// The skip keys on the structured REASON only — never on the status code —
// so ordinary capacity rejections (token_budget_exhausted / queue_full / cold
// "not loaded" misses, with or without a structured reason) flow through
// unchanged and the capacity-reject cooldown still sees every legitimate
// 503/404. The attempt's reservation-top-up refund and held-chunk discard
// (with its retry_precontent counter) run for EVERY reason:
// noteDispatchProviderError only feeds noteInferenceError for a non-nil
// provider, while the refund + held handling are unconditional.
func (d *execution) noteProviderError(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string, causes ...protocol.CoordinatorInferenceErrorCause) (discardedHeld bool) {
	if attemptpolicy.IsProviderHealthNeutralErrorReason(errReason) {
		provider = nil
	}
	return d.s.deps.Attempts().DispatchError(provider, pr, statusCode, errStr, errReason, terminalCause, held, causes...)
}

// shouldStopFailover is the single choke point that decides, after a dispatched
// attempt failed with outcomeRetry, whether the dispatch loop should STOP failing
// over because the request is unservable — rather than walk all 64 providers and
// 503 each. The orchestrator calls it at both post-dispatch retry points (after
// waitFirstChunk and waitAccepted), through which EVERY pre-content provider
// rejection funnels (including the speculative/race paths, which return their
// outcome up through waitFirstChunk). It inspects the just-recorded error
// (d.lastErr / d.lastErrReason via setLastInferenceError) and classifies it:
//
//   - DETERMINISTIC-context rejection (prompt > model context — identical on
//     every provider): stop on the FIRST occurrence. Retrying is pure waste
//     (prod: median 22 / max 63 futile attempts, ~8.7 min, 0% eventual success).
//   - TRANSIENT-capacity rejection (this node's KV budget / queue / drain): keep
//     failing over, but only up to maxCapacityClassRetries, then stop.
//   - DEADLINE-unreachable rejection (this node cannot land within the
//     request's remaining absolute clock): keep failing over without consuming
//     the generic capacity cap; exhausted candidates resolve to its own 429.
//   - genuine fault / timeout / unrecognised: return false → existing fault
//     failover (the per-provider breaker quarantines a persistently-sick node).
//
// When it returns true it sets d.unservable + d.unservableReason so the exhausted
// ladder emits exactly one uptime-neutral 429 (not a storm, not a raw 5xx). It is
// A deadline refusal also returns false but remains the current terminal. It is a
// no-op (returns false, no counters) for non-capacity outcomes, so timeouts and
// faults are unaffected.
//
// A previously-LATCHED verdict wins: a speculative race records the loser's error
// into speculative tracking, not d.lastErr (the surviving racer owns that), so a
// deterministic context overflow from a race loser would otherwise be masked by
// the survivor's later transient/timeout error and the loop would keep storming.
// latchDeterministicLoser sets d.unservable at the loser site; the guard below
// honors it at the first retry point regardless of what the survivor reported.
func (d *execution) shouldStopFailover() bool {
	// Honor a previously-latched verdict (incl. a client-shape 4xx latched from a
	// speculative race loser, whose code never lands in d.lastErrCode).
	if d.unservable || d.terminalClientError {
		return true
	}
	// StatusCode-driven stop BEFORE the string classifier: a deterministic provider
	// client 4xx is identical on every provider, so retrying is pure waste (the 29×
	// storm). String-blind on purpose — the code is ground truth here.
	if !d.s.deps.DisableClientErrorStop() && attemptpolicy.IsTerminalClientErrorCode(d.lastErrCode) {
		d.s.deps.Counters.Incr("routing.dispatch_client_error_stop", []string{"model:" + d.model, "code:" + strconv.Itoa(d.lastErrCode)})
		d.terminalClientError = true
		d.terminalClientErrorCode = d.lastErrCode
		return true
	}
	// Reason-driven stop (E4): a jinja_* error_reason is a DETERMINISTIC
	// template-render failure. It arrives as a provider 500 — which the
	// code-driven stop above deliberately ignores — but the model's chat
	// template renders the same request body identically on every provider,
	// so the ladder stops on the first occurrence and surfaces one 422
	// model_capability rejection. Kill switch: EIGENINFERENCE_JINJA_TERMINAL_REJECT.
	if d.latchJinjaTerminalReject(d.lastErrReason, "") {
		return true
	}
	// Timeout-class ladder cap: a coordinator-synthesized first-chunk timeout
	// is an untyped 504 (setLastError clears the typed cause for synthetic
	// terminals; a typed safety_deadline/backpressure_timeout 504 is a real
	// provider terminal and keeps its fault failover). The provider went
	// silent — a fresh provider MAY answer, so fail over, but each retry
	// costs a full fleet reservation scan; unbounded, that is the exact
	// CPU-amplification loop of the 2026-09-01 congestion collapse. Bounded
	// like maxCapacityClassRetries: at the cap the ladder exhausts and the
	// synthetic 504 reclassifies to the retryable 429 with reason
	// "first_chunk_timeout" (classifyExhaustedStatus). Same discriminator as
	// waitFirstChunk's route-outcome writer, so a timeout never double-counts
	// as anything else. Behavior below the cap is unchanged: classifyRejection
	// already returns rejectionNotCapacity for the synthetic timeout string
	// (see rejection_classify_test.go), i.e. "keep failing over".
	if d.lastErrCode == http.StatusGatewayTimeout && !attemptpolicy.IsTypedTimeout504Cause(d.lastErrTerminalCause) {
		d.firstChunkTimeoutRetries++
		if d.firstChunkTimeoutRetries >= maxFirstChunkTimeoutRetries {
			d.s.deps.Counters.Incr("routing.first_chunk_timeout_ladder_capped", []string{"model:" + d.model})
			return true
		}
		return false
	}
	// Typed-cause override (highest-fidelity signal): a provider that attaches
	// terminal_cause=admission_timeout is TELLING us its engine was too busy to
	// admit the request within the admission lease — definitionally a
	// this-node transient-capacity condition (a healthier/idler provider may
	// serve). Without this, the fixed "admission_timeout: …" error text falls
	// through the legacy capacity substrings, gets classified as a generic
	// fault, and walks the unbounded fault-failover ladder to a final 503
	// instead of the bounded capacity retries and uptime-neutral 429.
	kind := attemptpolicy.ClassifyRejection(d.lastErrReason, d.lastErr, d.lastErrProviderBudget, d.modelMaxContext, d.lastErrRejectionReason)
	if kind != attemptpolicy.RejectionDeadlineUnreachable &&
		d.lastErrTerminalCause == attemptpolicy.TerminalCauseAdmissionTimeout {
		kind = attemptpolicy.RejectionTransientCapacity
	}
	switch kind {
	case attemptpolicy.RejectionDeterministicUnservable:
		d.s.deps.Counters.Incr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:deterministic"})
		d.unservable = true
		d.unservableReason = rejectionReasonOversized
		return true
	case attemptpolicy.RejectionDeadlineUnreachable:
		// This provider declined only the remaining request-absolute SLA.
		// Another untried provider may still land, so keep failing over without
		// consuming the generic transient-capacity retry allowance.
		d.lastFailureDeadline = true
		return false
	case attemptpolicy.RejectionTransientCapacity:
		if attemptpolicy.IsDrainingErrorReason(d.lastErrReason) {
			// Typed drain refusal (R2): the provider is restarting, not the
			// fleet full. Keep failing over (the provider is now marked
			// draining and excluded) WITHOUT charging the request's bounded
			// transient-capacity allowance — a drain wave must not turn into
			// 429s for requests the rest of the fleet can serve.
			d.s.deps.Counters.Incr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:draining"})
			return false
		}
		d.s.deps.Counters.Incr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:transient"})
		d.capacityRetries++
		if d.capacityRetries >= maxCapacityClassRetries {
			d.unservable = true
			d.unservableReason = rejectionReasonOversized
			return true
		}
		return false
	default:
		return false
	}
}

// latchJinjaTerminalReject latches the terminal 422 for a deterministic
// template-render failure and reports whether it latched — a no-op returning
// false when the kill switch (envJinjaTerminalReject) is off or reason is not
// jinja_*. It is the SINGLE jinja-stop point shared by shouldStopFailover
// (survivor path) and latchDeterministicLoser (race-loser mirror), so the
// enable+reason guard and the latched fields cannot drift between the two
// sites. The latched code is OUR classification (422 Unprocessable Entity —
// the request is well-formed but unrenderable by this model), not the
// provider's raw 500. src tags the metric emission site ("" = the
// shouldStopFailover survivor path, "race_loser" = latchDeterministicLoser).
func (d *execution) latchJinjaTerminalReject(reason, src string) (latched bool) {
	if !JinjaTerminalRejectEnabled() || !attemptpolicy.IsJinjaTemplateErrorReason(reason) {
		return false
	}
	tags := []string{"model:" + d.model, "code:422", "reason:" + attemptpolicy.NormalizeInferenceErrorReason(reason)}
	if src != "" {
		tags = append(tags, "src:"+src)
	}
	d.s.deps.Counters.Incr("routing.dispatch_client_error_stop", tags)
	d.terminalClientError = true
	d.terminalClientErrorCode = http.StatusUnprocessableEntity
	d.terminalClientErrorReason = rejectionReasonTemplateRenderFailed
	d.terminalClientErrorMessage = JinjaTerminalRejectMessage
	return true
}

// latchDeterministicLoser preserves a DETERMINISTIC-unservable rejection observed
// from a speculative race LOSER. A race loser's error is recorded into speculative
// tracking but NOT written to d.lastErr (the surviving racer owns that), so without
// this latch a deterministic context overflow from the loser would be masked by the
// survivor's later transient/timeout error and the dispatch loop would keep storming
// the fleet (the exact gap shouldStopFailover otherwise closes only on the non-
// speculative path). Once latched, shouldStopFailover stops at the next retry point
// regardless of the survivor's outcome. It is budget-aware (see classifyRejection):
// a memory-pressured loser's "batch token budget" is NOT latched, so failover to a
// healthier provider still happens. Harmless if the survivor ultimately succeeds —
// d.unservable is only consulted on the exhausted/retry path, never on a commit.
func (d *execution) latchDeterministicLoser(provider *registry.Provider, msg protocol.InferenceErrorMessage) {
	msg = attemptpolicy.NormalizeInferenceErrorForInternalUse(msg)
	// Same budget preference as setLastInferenceError: the enriched LIVE
	// gate budget (explicit zero included) supersedes the stale heartbeat
	// snapshot for this loser's classification.
	budget := providerReportedBudget(provider, d.model)
	if msg.AvailableTokenBudget != nil {
		budget = *msg.AvailableTokenBudget
	}
	d.captureGenuineFault(provider, msg, budget)
	if d.unservable || d.terminalClientError {
		return
	}
	// Mirror the StatusCode stop at the race-loser site: the loser's error is NOT
	// written to d.lastErr (the survivor owns it), so without this a deterministic
	// client 4xx from the loser is masked and the storm resumes via the survivor.
	if !d.s.deps.DisableClientErrorStop() && attemptpolicy.IsTerminalClientErrorCode(msg.StatusCode) {
		d.s.deps.Counters.Incr("routing.dispatch_client_error_stop", []string{"model:" + d.model, "code:" + strconv.Itoa(msg.StatusCode), "src:race_loser"})
		d.terminalClientError = true
		d.terminalClientErrorCode = msg.StatusCode
		// The verdict slot owns the terminal outcome's kv_backend attribution
		// from this point (see latchTerminalAttribution): the response the
		// client gets IS this loser's 4xx, whatever the surviving racer does.
		d.latchTerminalAttribution(provider)
		return
	}
	// Mirror the jinja_* reason stop (E4) at the race-loser site for the same
	// masking reason: a deterministic template-render failure from the loser
	// must not be storm-resumed through the survivor's transient error.
	if d.latchJinjaTerminalReject(msg.ErrorReason, "race_loser") {
		d.latchTerminalAttribution(provider)
		return
	}
	switch attemptpolicy.ClassifyRejection(msg.ErrorReason, msg.Error, budget, d.modelMaxContext, msg.RejectionReason) {
	case attemptpolicy.RejectionDeadlineUnreachable:
		// A race loser that could not meet the remaining absolute deadline is
		// health-neutral and non-deterministic across providers. It must not
		// become sticky: the surviving attempt owns the eventual terminal.
	case attemptpolicy.RejectionDeterministicUnservable:
		d.s.deps.Counters.Incr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:deterministic"})
		d.unservable = true
		d.unservableReason = rejectionReasonOversized
		d.latchTerminalAttribution(provider)
	}
}
