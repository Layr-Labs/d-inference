package inference

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inresp "github.com/eigeninference/d-inference/coordinator/api/inference/response"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	routeoutcome "github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	profilepolicy "github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	rejection "github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	retry "github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// dispatchOutcome is the result of a per-attempt dispatch phase (provider
// selection, first-chunk wait, accepted wait). The orchestrator (attempt.Loop)
// switches on it to reproduce the original loop's continue/break/return flow.
type dispatchOutcome = attempt.Outcome

const (
	// outcomeCommitted: a content chunk (or a clean close) committed the attempt.
	// The orchestrator stops the loop and streams the response.
	outcomeCommitted = attempt.Committed

	// outcomeRetry: the attempt failed (provider error / timeout). Equivalent to
	// the original `continue dispatch` — the orchestrator advances to the next attempt.
	outcomeRetry = attempt.Retry

	// outcomeClientGone: the request context was cancelled; the reservation was
	// already refunded and the handler must return with no response body.
	outcomeClientGone = attempt.ClientGone
)

type dispatchTerminalFailure = retry.TerminalFailure

// dispatchState carries everything the per-request dispatch loop needs. The
// immutable inputs are set once by runDispatch; the mutable fields track the
// in-flight attempt (selected provider, held preamble, commit/accept flags,
// last error for the exhaustion ladder, and the version to steer retries away from).
type dispatchState struct {
	s           *Owner
	retryPolicy *retry.Controller

	// ---- immutable inputs (set once) ----
	w                      http.ResponseWriter
	r                      *http.Request
	model                  string
	publicModel            string
	rawBody                []byte
	consumerKey            string
	consumerLocation       *store.ProviderLocation
	reservedMicroUSD       int64
	serviceReservation     bool
	estimatedPromptTokens  int
	requestedMaxTokens     int
	tokenAdmission         registry.TokenAdmission
	requiresVision         bool
	hasTools               bool
	requiresToolConstraint bool
	toolChoiceMode         string
	toolChoiceName         string
	parallelToolCalls      bool
	isResponsesAPI         bool
	consumerEndpoint       string
	requestedStopSequences []string
	stream                 bool
	metadataDetails        bool
	policy                 selfRoutePolicy
	allowedProviderSerials []string
	cachePlan              registry.CachePlan
	timing                 *registry.RequestTiming
	profile                *registry.RequestProfile
	deadline               time.Duration
	fallbackDeadline       time.Duration
	promptDeadlineForWork  func(string, *protocol.PromptWork) time.Duration
	speculativeAt          time.Duration
	// modelMaxContext is the model's context window (0 = unknown), used by
	// shouldStopFailover/classifyRejection to tell a fleet-wide context overflow
	// apart from a memory-pressured provider's shrunk KV budget when a "batch token
	// budget" rejection arrives.
	modelMaxContext int
	// refundReservation refunds the shared base reservation (the caller's closure).
	refundReservation func()

	// ---- mutable per-request state ----
	provider      *registry.Provider
	pr            *registry.PendingRequest
	requestID     string
	firstChunk    string
	heldChunks    []string
	initialError  *protocol.InferenceErrorMessage
	lastErr       string
	lastErrCode   int
	lastErrReason string
	// lastErrProviderBudget is the rejecting provider's reported token budget
	// (ActiveTokenBudgetMax) for d.model at the time lastErr was set, or 0 when the
	// error is not a provider rejection / the provider reported no budget. Captured
	// by setLastInferenceError so shouldStopFailover can classify a "batch token
	// budget" rejection as deterministic (budget >= context) vs transient
	// (budget < context — this node was memory-pressured).
	lastErrProviderBudget int64
	// lastErrRejectionReason is the typed CapacityRejectionReason from the
	// last provider error ("" for legacy providers). classifyRejection
	// treats a typed token_budget as AUTHORITATIVE transient: the provider's
	// live gate named the shortage, so a deterministic-unservable verdict
	// must never be re-derived from the stale heartbeat budget fallback.
	lastErrRejectionReason protocol.CapacityRejectionReason
	// lastErrTerminalCause is the typed terminal_cause from the last provider
	// error ("" for legacy providers). shouldStopFailover trusts a typed
	// admission_timeout as transient capacity directly — the provider's engine
	// TOLD us it was busy — instead of inferring from error-string substrings
	// that the fixed "admission_timeout: …" text would never match.
	lastErrTerminalCause string
	// lastErrCoordinatorCause is a non-wire marker for coordinator-synthetic
	// terminals such as a provider disconnect. A provider cannot set it.
	lastErrCoordinatorCause protocol.CoordinatorInferenceErrorCause
	// lastErrAttemptUsage is the typed partial usage from the last provider
	// error (nil for legacy providers), applied to the failed attempt's route
	// row by providerFailedRoutingOutcomeFor so pre-content typed failures on
	// the ordinary dispatch path keep their observability data.
	lastErrAttemptUsage *protocol.UsageInfo
	// terminalEvidence is request-wide terminal precedence, separate from the
	// lastErr* per-attempt scratch used to persist each attempt's route outcome.
	// Capacity/lifecycle refusals, deadline refusals, neutral typed causes, and
	// deterministic client/model errors never enter this slot.
	terminalEvidence  retry.TerminalEvidence
	committed         bool
	lastFailedVersion string
	excludeProviders  map[string]struct{}
	// capacityRetries counts pre-content TRANSIENT-capacity failovers (this
	// node's live KV budget, a full queue, a drain). Bounded by
	// maxCapacityClassRetries so a fleet-wide transient cannot storm; a
	// DETERMINISTIC-context rejection (prompt > model context) stops on the first
	// attempt regardless (see classifyRejection / failoverOutcome).
	capacityRetries int
	// Predictive refusals are request-local evidence, never provider faults.
	predictiveRefusals int
	forecast           *firstcontent.Forecast
	freshFeasibleAfter time.Time
	speculative        *Speculative
	// firstChunkTimeoutRetries counts attempts that ended in a
	// coordinator-synthesized first-chunk TIMEOUT (untyped 504 → the
	// "first_chunk_timeout" 429 on exhaustion). Bounded by
	// retry.Controller so a slow-provider storm cannot burn a
	// fresh fleet scan per attempt across the ladder (the 2026-09-01
	// congestion collapse). Each counted attempt was on a
	// distinct provider — the timed-out provider joins excludeProviders.
	firstChunkTimeoutRetries int
	// lastFailureDeadline is scoped to the most recent terminal attempt. A
	// deadline refusal remains eligible for deadline_unreachable only while no
	// later genuine provider fault has replaced it.
	lastFailureDeadline bool
	// unservable is set when the dispatch loop stops because the request cannot
	// be served (deterministic-context rejection, or a transient that exhausted
	// maxCapacityClassRetries). The exhausted ladder then emits a single
	// uptime-neutral 429 with unservableReason instead of retrying/5xx'ing.
	unservable       bool
	unservableReason string
	// terminalClientError is set when a dispatched provider returned a DETERMINISTIC
	// client-shape 4xx (400/413/422/415 — invalid tool payload / role / response_format
	// / unsupported media). That rejection is identical on every provider (the bad
	// request body is forwarded unchanged), so the loop stops immediately and the
	// exhausted ladder surfaces terminalClientErrorCode ONCE — instead of failing over
	// up to maxDispatchAttempts (the prod 29×/max-63 storm). String-blind: the status
	// code is ground truth; the human-readable provider string drifts across versions.
	terminalClientError     bool
	terminalClientErrorCode int
	// terminalClientErrorReason, when non-empty, overrides the exhausted
	// ladder's rejection-ledger reason_code for a latched terminal client
	// error ("template_render_failed" for the jinja_* stop — distinguishable
	// from the StatusCode-driven stop's generic "client_error").
	terminalClientErrorReason string
	// terminalClientErrorMessage, when non-empty, overrides the surfaced
	// error-body message (the jinja_* stop surfaces the curated
	// model_capability text, not the provider's raw template backtrace).
	terminalClientErrorMessage string
	// servedKVSlot latches the KV-cache backend attribution of the SLOT the
	// most recent attempt was dispatched to (v0.8.0 paged rollout, Gate G5) —
	// the resolved kind AND whether that kind was a silent degrade. It is NOT
	// per-attempt scratch: the failure tails run after a retry has cleared
	// d.provider/d.pr, and a 5xx from a paged slot that just fell over is
	// exactly the sample the rollout dashboard must not lose. Zero value until
	// the request reaches a slot, which tags unknown on both dimensions.
	servedKVSlot *backend.Latch

	// ---- Routing v2 wave-2 plan/hedge state ----
	// retainedPlan shares bounded selection and quote-refresh budgets between
	// failover retries and the speculative backup.
	retainedPlan *providerdispatch.Plan
	// hedgeAdvanceCh delivers the probe round's refined ABSOLUTE speculative
	// launch instant (hedgeLaunchAt) when a confirmed backup's quoted q90
	// proves the 50% point too late to be useful. Buffered 1, written at most
	// once by the quote collector; nil until probes launch. waitFirstChunk
	// consumes at most one value under only-earlier / only-once /
	// never-after-fire guards; without a value the 50% default stands.
	hedgeAdvanceCh <-chan time.Time
	// hedgeGovernorVerdict is the governor's decision for this request's
	// speculative launch ("" = the governor never ran: no speculative point
	// reached, or an owner-served prefer request). Telemetry/log only.
	hedgeGovernorVerdict string
	// providerDispatches counts inference frames actually handed to a
	// provider — primary, queued, plan-retry, and speculative-backup sends
	// alike, incremented only after the writer confirms final authorization
	// and socket handoff. Client-visible exhaustion messages report this
	// machine count; route rows keep the loop index d.attempt untouched.
	sendAccounting *providerwire.Accounting
	// visionImageCount is the number of media parts in the request (0 for
	// text-only), carried into capacity probes as count-only shape metadata.
	visionImageCount int
	// lastErrFeasibleAfterMS is the enriched rejection's forecast of when a
	// request of this shape could next be admitted (0 = absent/legacy),
	// captured by setLastInferenceError and surfaced into the exhaustion
	// 429's Retry-After.
	lastErrFeasibleAfterMS int64

	// ---- per-attempt scratch (reset each attempt) ----
	attempt          int
	preambleLiveness bool
	// dispatchErr captures the non-empty error string from dispatchOneProvider
	// for this attempt so outcome telemetry can classify the routing decision.
	dispatchErr string
	// dispatchErrCode captures the HTTP status code associated with dispatchErr.
	dispatchErrCode int
	// providerBodyTooLargeErr preserves a protocol-0 cache-buster overflow
	// while failover tries providers whose newer protocol does not add it.
	providerBodyTooLargeErr   string
	providerBodyTooLargeBytes int
	minPrefixCacheProtocol    int
}

// traits builds the routing traits for the current attempt, steering away from
// the most recently failed provider's binary version.
func (d *dispatchState) traits() registry.RequestTraits {
	return d.currentTerminalFailure().RetryTraits(registry.RequestTraits{
		HasTools:               d.hasTools,
		RequiresToolConstraint: d.requiresToolConstraint,
		ToolChoiceMode:         d.toolChoiceMode,
		ToolChoiceName:         d.toolChoiceName,
		ParallelToolCalls:      d.parallelToolCalls,
		AvoidVersion:           d.lastFailedVersion,
		MinPrefixCacheProtocol: d.minPrefixCacheProtocol,
	})
}

// envTTFTTerminalReject is the kill switch for the terminal TTFT-rejection fix.
// A reservation that fails because every candidate exceeds the TTFT ceiling
// (errTTFTTooSlow) is DETERMINISTIC: it is computed from the same fleet-wide
// estimate on every scan, so re-running it within the same request cannot
// succeed. Default true: the dispatch ladder stops on the FIRST such rejection
// at ANY attempt and returns the same 429 the attempt-0 path always produced
// (prod: mid-ladder rejections previously looped to maxDispatchAttempts,
// re-running the doomed scan ~63x per request and writing a ttft_429 route row
// each time — 28% of inference_routes). Set =false to restore the legacy
// attempt-0-only fast path. Read live (not a Server field) following the
// cold_dispatch.go flag pattern, so it stays confined to this file and is
// overridable in tests via t.Setenv.
const envTTFTTerminalReject = "EIGENINFERENCE_TTFT_TERMINAL_REJECT"

// ttftTerminalRejectEnabled reports whether a TTFT-too-slow reservation
// rejection terminates the dispatch ladder on any attempt. Default true.
func ttftTerminalRejectEnabled() bool {
	return retry.EnvEnabledDefaultTrue(envTTFTTerminalReject)
}

// queueMaxTTFTMs returns the TTFT ceiling for queued requests. Public routes
// inherit the prompt-scaled admission threshold; self-route / prefer-owner paths
// are not subject to the public SLA ceiling.
//
// When hardReject is false (the default soft gate), a zero ceiling is returned
// so the scheduler's enforceTTFT path is disabled: candidates over the estimated
// deadline are no longer dropped (and no errTTFTTooSlow is produced). The router
// still ranks by cost (which is TTFT-weighted), so the fastest provider wins, but
// a request is served on the best-available provider instead of being rejected
// on a pessimistic prefill estimate.
func queueMaxTTFTMs(policy selfRoutePolicy, deadline time.Duration, hardReject bool) float64 {
	return routeplan.QueueTTFTCeiling(providerdispatch.Scope{SelfRouteOnly: policy.enabled, PreferOwner: policy.prefer}, deadline, hardReject)
}

func (s *Owner) recordRoutingDecision(in providerdispatch.Input, provider *registry.Provider, pr *registry.PendingRequest, requestID string, attempt int, decision registry.RoutingDecision, dispatchErr, outcomeOverride string) {
	s.NewRouteRecorder().RecordDecision(in, provider, pr, requestID, attempt, decision, dispatchErr, outcomeOverride)
}

// commitFirstContent publishes content before the response or route outcome.
func (d *dispatchState) commitFirstContent(pr *registry.PendingRequest, chunk string) {
	d.firstChunk = d.s.NewContentCommitter().Commit(d.profile, pr, len(d.heldChunks), chunk).FirstChunk
}

func (d *dispatchState) successRoutingOutcomeFor(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return routeoutcome.CommittedRouteOutcome(pr)
}

func (d *dispatchState) errorRoutingOutcomeFor(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	return retry.ErrorRouteOutcome(pr, status, class, protocol.InferenceErrorMessage{
		Error: d.lastErr, ErrorReason: d.lastErrReason, StatusCode: code,
	})
}

func (d *dispatchState) setLastError(errText string, statusCode int) {
	msg := retry.CoordinatorFailure(errText, statusCode).Message
	d.lastErr = msg.Error
	d.lastErrCode = msg.StatusCode
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

func (d *dispatchState) currentTerminalFailure() dispatchTerminalFailure {
	reason := ""
	if d.lastFailureDeadline {
		reason = failure.ErrorReasonDeadlineUnreachable
	}
	return retry.NewTerminalFailure(protocol.InferenceErrorMessage{
		Error: d.lastErr, StatusCode: d.lastErrCode,
		TerminalCause: d.lastErrTerminalCause, ErrorReason: reason,
	}, backend.Slot{})
}

const (
	exhaustedUndecided    = retry.Undecided
	exhaustedClientError  = retry.ClientError
	exhaustedGenuineFault = retry.GenuineFault
	exhaustedUnservable   = retry.Unservable
	exhaustedDeadline     = retry.Deadline
)

func (d *dispatchState) applyBodyPreparation(result PrimaryHistory) {
	d.providerBodyTooLargeErr, d.providerBodyTooLargeBytes = result.Overflow.Message, result.Overflow.Bytes
	d.setLastError(result.Failure.Message.Error, result.Failure.Message.StatusCode)
}

func (d *dispatchState) preflightLegacyCacheBust() {
	traits, _ := providerwire.RoutingTraits(d.hasTools, d.rawBody)
	if traits.MinPrefixCacheProtocol > 0 {
		d.minPrefixCacheProtocol = traits.MinPrefixCacheProtocol
	}
}

func (d *dispatchState) latchProviderBodyTooLarge(errText string) {
	result := (PrimaryHistory{Overflow: ProviderBodyOverflow{Bytes: d.providerBodyTooLargeBytes}}).RejectBodyOverflow(errText)
	d.applyBodyPreparation(result)
	d.terminalClientError = true
	d.terminalClientErrorCode = result.Terminal.ClientStatus
	d.terminalClientErrorReason = result.Terminal.ClientReason
	d.terminalClientErrorMessage = result.Terminal.ClientMessage
}

// setLastInferenceError records a pre-content provider rejection as the dispatch
// loop's last error and snapshots the rejecting provider's reported token budget
// for d.model. shouldStopFailover needs that budget to tell a fleet-wide
// DETERMINISTIC context overflow apart from THIS node's memory-pressured KV budget
// (see classifyRejection). provider may be nil (budget 0 = unknown).
func (d *dispatchState) setLastInferenceError(provider *registry.Provider, msg protocol.InferenceErrorMessage) {
	evidence := d.terminalEvidence.Observe(provider, d.model, msg, d.modelMaxContext, d.backendLatch())
	msg, providerBudget := evidence.Message, evidence.ProviderBudget
	d.lastErr = msg.Error
	d.lastErrCode = msg.StatusCode
	d.lastErrReason = msg.ErrorReason
	d.lastFailureDeadline = failure.IsDeadlineUnreachableErrorReason(msg.ErrorReason)
	if d.lastFailureDeadline {
		d.notePredictiveRefusal(provider)
	}
	d.lastErrProviderBudget = providerBudget
	d.lastErrRejectionReason = msg.RejectionReason
	d.lastErrTerminalCause = msg.TerminalCause
	d.lastErrCoordinatorCause = msg.CoordinatorCause
	d.lastErrAttemptUsage = msg.AttemptUsage
	d.lastErrFeasibleAfterMS = msg.FeasibleAfterMS
}

func (d *dispatchState) providerFailedRoutingOutcomeFor(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return (retry.AttemptFailure{Message: protocol.InferenceErrorMessage{
		Error: d.lastErr, StatusCode: d.lastErrCode, ErrorReason: d.lastErrReason,
		CoordinatorCause: d.lastErrCoordinatorCause, AttemptUsage: d.lastErrAttemptUsage,
	}}).RouteOutcome(pr)
}

func dispatchErrorClass(errText string) string {
	return profilepolicy.DispatchErrorClass(errText)
}

func (d *dispatchState) rejectionInfo(stage, reason string, status, retryAfterMs int) rejection.Prepared {
	return rejection.BuildDispatch(d.r, rejection.DispatchMetadata{
		Model: d.model, PublicModel: d.publicModel, ConsumerKey: d.consumerKey, Stream: d.stream,
		EstimatedPromptTokens: d.estimatedPromptTokens, RequestedMaxTokens: d.requestedMaxTokens,
		RequiresVision: d.requiresVision, HasTools: d.hasTools, SelfRouteOnly: d.policy.enabled,
		PreferOwner: d.policy.prefer, OverflowBodyBytes: d.providerBodyTooLargeBytes,
	}, stage, reason, status, retryAfterMs, nil)
}

// dispatchRoutingAttempt is immutable identity captured before a wait path can
// clear or promote mutable dispatchState provider/request fields.
type dispatchRoutingAttempt = routeoutcome.Attempt

func routingAttempt(provider *registry.Provider, pr *registry.PendingRequest, requestID string, attempt int) dispatchRoutingAttempt {
	return routeoutcome.CaptureAttempt(provider, pr, requestID, attempt)
}

func (d *dispatchState) currentOrCapturedRoutingAttempt(captured dispatchRoutingAttempt) dispatchRoutingAttempt {
	return routeoutcome.CurrentOrCaptured(captured, d.provider, d.pr, d.requestID, d.attempt)
}

// emitClientGone records a before-first-token cancellation on the
// d_inference.routing.client_gone counter for this attempt. It reads
// the current candidate's chip family (or "unknown" when no provider is selected
// yet, e.g. a queue-wait cancel) and the estimated prompt-token bucket. Called
// once per logical client_gone at the central classification sites so speculative
// speculative backup bookkeeping never double-counts.
func (d *dispatchState) emitClientGone(phase string) {
	d.s.emitClientGone(d.model, d.estimatedPromptTokens, d.provider, d.profile, d.clientGoneDeadlineBucket(), phase)
}

func (s *Owner) emitClientGone(model string, promptTokens int, provider *registry.Provider, profile *registry.RequestProfile, bucket, phase string) {
	profilepolicy.StampClientGone(profile, phase)
	// deadline_bucket: elapsed on the request clock vs the first-content
	// budget. At/past ~the budget the upstream timed out on us (its 504), so
	// the OR-view outcome is `timeout`; earlier it is an excluded client abort.
	s.NewMetrics().ClientGoneBucketed(model, promptTokens, observation.ProviderChipFamily(provider), phase, bucket)
	s.NewMetrics().RecordORView(model, infermetrics.ORViewClassForClientGone(bucket))
}

func (d *dispatchState) selectPrimary() attempt.SelectionResult {
	result := d.s.NewPrimary(PrimaryResources{
		Plan: d.dispatchPlan(), Accounting: d.accounting(), Slots: d.backendLatch(),
	}).Run(d.primaryRequest())
	d.applyPrimaryResult(result)
	terminal := result.History.Terminal
	return attempt.SelectionResult{Outcome: result.Outcome, Terminal: retry.TerminalPolicy{
		ClientError: terminal.ClientStatus != 0, ClientStatus: terminal.ClientStatus,
		ClientReason: terminal.ClientReason, Unservable: terminal.UnservableReason != "",
		UnservableReason: terminal.UnservableReason,
	}}
}

// noteDispatchRetry feeds the inference-error breaker + refund for a pre-commit
// provider error and, unless held boilerplate was discarded (which emits its own
// pre-content failover counter), emits the generic retry counter. This is the
// same retry.Effects operation used by speculative and first-wait failures.
func (d *dispatchState) noteDispatchRetry(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string, causes ...protocol.CoordinatorInferenceErrorCause) {
	d.s.NewAttemptEffects().Retry(provider, pr, statusCode, errStr, errReason, terminalCause, held, causes...)
}

// rejectionReasonQueueDeadline is the rejection-ledger reason_code for a
// request whose request-absolute first-content clock expired while it was
// still waiting in the coordinator queue. Nothing was dispatched — it is the
// queue's own terminal, kept distinct from first_chunk_timeout (a dispatched
// provider that produced no content in time) so telemetry stops conflating
// queue expiry with provider silence. Same retryable 429 + Retry-After.
const rejectionReasonQueueDeadline = retry.QueueDeadlineReason

// errQueueDeadlineExpired is the latched error text for that terminal; the
// exhausted ladder keys the queue_deadline reason on it.
const errQueueDeadlineExpired = retry.QueueDeadlineError

// rejectionReasonRoutingSaturated is the rejection-ledger reason_code for a
// request shed because no provider-selection scan slot freed up within its
// remaining first-content budget (Server.routingScanSem — the coordinator
// itself was the bottleneck, 2026-09-01 collapse). Capacity-shaped: one
// retryable 429, uptime-neutral, zero providers contacted.
const rejectionReasonRoutingSaturated = "routing_saturated"

// rejectionReasonDeadlineUnreachable is the rejection-ledger reason for a
// request whose remaining absolute first-content budget was refused by one or
// more providers and whose untried candidates were then exhausted.
const rejectionReasonDeadlineUnreachable = failure.ErrorReasonDeadlineUnreachable

// runSpeculative is the speculativeTimer.C arm of waitFirstChunk: the primary is
// slow, so dispatch a speculative backup (unless this is a prefer request being
// served by the caller's own machine) and either keep waiting for the primary
// alone (no backup available) or race primary vs backup. Returns the same outcome
// set as waitFirstChunk.
func (d *dispatchState) runSpeculative() dispatchOutcome {
	if d.speculative == nil {
		d.speculative = d.s.NewSpeculative(d.dispatchPlan())
	}
	result := d.speculative.Run(SpeculativeRequest{
		Dispatch: d.dispatchInput(d.timing, d.excludeProviders, "", nil),
		Primary:  d.provider, Pending: d.pr, RequestID: d.requestID,
		Metadata: providerdispatch.PendingMetadata{
			Endpoint: d.consumerEndpoint, StopSequences: d.requestedStopSequences, Details: d.metadataDetails,
		},
		SpeculativeAt: d.speculativeAt,
		Failure: retry.AttemptFailure{Message: protocol.InferenceErrorMessage{
			Error: d.lastErr, ErrorReason: d.lastErrReason,
		}},
	}, SpeculativeWaits{
		NoBackup: func(overflow *PrimaryHistory) attempt.Outcome {
			if overflow != nil {
				d.applyBodyPreparation(*overflow)
			}
			return d.waitNoBackup()
		},
		Accepted: d.waitAccepted,
		Race:     d.runRace,
	})
	d.hedgeGovernorVerdict = result.GovernorVerdict
	return result.Outcome
}

// waitNoBackup is the speculative-no-backup branch (`noBackupWait`): keep waiting
// for the primary alone with the remaining deadline. d.provider / d.pr are the primary.
func (d *dispatchState) waitNoBackup() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr
	timeout := d.newWaitTimeout()
	wait := attempt.NewSingleWait(attempt.SingleWaitDependencies{
		Commit: func(chunk string) { d.commitFirstContent(pr, chunk) },
		CommitReady: func(msg protocol.InferenceErrorMessage) bool {
			return d.commitReadyFirstContent(pr, &d.heldChunks, msg)
		},
		Failure: func(errMsg protocol.InferenceErrorMessage, countRetry bool) {
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatchAfterTerminal(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			if countRetry && s.observation.Metrics() != nil {
				s.observation.Metrics().IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
			d.provider = nil
			d.pr = nil
		},
		Timeout: func() bool {
			result := timeout.Run(r.Context(), attempt.NoBackupTimeout, d.firstContentClock().ForPending(pr).Duration(d.deadline))
			if !result.Claimed {
				return false
			}
			d.excludeProviders[provider.ID] = struct{}{}
			d.setLastError(result.Failure.Message.Error, result.Failure.Message.StatusCode)
			d.provider = nil
			d.pr = nil
			return true
		},
		ClientGone: func() {
			s.cancelDispatch(provider, pr, cancellation.CauseClientGonePre)
			d.refundReservation()
		},
	}, pr, d.firstContentClock(), d.deadline-d.speculativeAt)
	result := wait.Run(r.Context(), &d.heldChunks)
	if result.Outcome == outcomeCommitted {
		d.committed = true
	}
	if result.PreambleLiveness {
		d.preambleLiveness = true
	}
	return result.Outcome
}

// runRace is the speculative `race` loop: primary (d.provider/d.pr) vs backup,
// first CONTENT chunk wins; the loser is cancelled. Preamble from each racer is
// buffered separately (held chunks must never mix providers). On a racer error the
// surviving racer is waited on via a sub-loop. Returns the waitFirstChunk outcome
// set; on a backup win d.provider/d.pr/d.requestID/d.heldChunks are swapped to the backup.
func (d *dispatchState) runRace(backupProvider *registry.Provider, backupPR *registry.PendingRequest) dispatchOutcome {
	return d.finishRace(d.newRace().Run(d.r.Context(), d.raceAttempt(), attempt.RaceAttempt{Provider: backupProvider, Pending: backupPR, RequestID: backupPR.RequestID}))
}

func (d *dispatchState) finishDispatch(loopResult attempt.LoopResult) {
	s := d.s
	w, r := d.w, d.r
	if !d.committed {
		d.refundReservation()
		if d.providerBodyTooLargeErr != "" &&
			d.lastErrCode == http.StatusRequestEntityTooLarge {
			d.latchProviderBodyTooLarge(d.providerBodyTooLargeErr)
			loopResult.Terminal.ClientError = true
			loopResult.Terminal.ClientStatus = d.terminalClientErrorCode
			loopResult.Terminal.ClientReason = d.terminalClientErrorReason
		}
		failure, stickyFault := d.terminalEvidence.Select(d.currentTerminalFailure(), loopResult.Terminal.ClientError)
		statusCode, reason, timeoutReclassified, dominance :=
			retry.ResolveTerminal(failure, stickyFault, loopResult.Terminal)
		if timeoutReclassified {
			s.observation.Incr("routing.first_chunk_timeout_reclassified", []string{"model:" + d.model, "reason:" + reason})
		}
		switch dominance {
		case exhaustedClientError:
			// Deterministic provider client 4xx (identical fleet-wide): pass the real
			// code through ONCE. Checked BEFORE d.unservable / statusCode==0 so it can
			// never be reclassified to 429/503 — this is a client fault, not capacity.
			s.observation.Incr("routing.client_error_passthrough", []string{"model:" + d.model, "code:" + strconv.Itoa(statusCode)})
		case exhaustedGenuineFault:
			// A genuine provider fault observed on any pre-content attempt is
			// request-terminal precedence. Later neutral deadline/capacity
			// refusals still own their own route rows but cannot hide the fault.
		case exhaustedUnservable:
			// The loop stopped early because no provider can serve this request
			// (deterministic context overflow, or a capacity transient that
			// exhausted maxCapacityClassRetries). We already know the verdict, so
			// skip the quick-capacity probe and the 5xx→429 reclassification below:
			// emit a single uptime-neutral 429. This is the proactive complement to
			// the always-on backstop — it converts the request BEFORE storming the
			// fleet, not after 64 attempts.
			s.observation.Incr("routing.oversized_request_rejected", []string{"model:" + d.model, "stage:dispatch"})
		case exhaustedDeadline:
			// Every refusal was health-neutral and did not consume the generic
			// capacity retry cap. Once no untried candidate remains, expose one
			// uptime-neutral 429 with its own closed reason.
			s.observation.Incr("routing.deadline_unreachable_rejected", []string{"model:" + d.model, "stage:dispatch"})
		case exhaustedUndecided:
			if statusCode == 0 {
				// Distinguish capacity exhaustion (429) from genuine unavailability (503).
				// A quick capacity check tells us if providers exist but are full.
				_, capRej, _ := s.registry.QuickCapacityCheckForRequest(
					d.model, d.estimatedPromptTokens, d.requestedMaxTokens,
					d.traits(), d.requiresVision, d.allowedProviderSerials...)
				if capRej > 0 {
					statusCode = http.StatusTooManyRequests
				} else {
					statusCode = http.StatusServiceUnavailable
				}
			} else if statusCode >= 500 && rejection.IsCapacityClassProviderError(failure.ErrorText()) {
				// Backstop (always on): the provider admitted the request then
				// rejected it because (prompt+max_tokens) overflowed its token budget /
				// KV / context — a capacity condition, not a server fault. Return an
				// uptime-neutral 429 (OpenRouter fails over) instead of the raw 5xx,
				// which would count against our uptime. Fires only on a real provider
				// rejection, so it cannot over-reject servable traffic.
				statusCode = http.StatusTooManyRequests
				reason = "unservable_token_budget"
				s.observation.Incr("routing.unservable_reclassified", []string{"model:" + d.model})
			}
		}
		observation.MarkCoordinatorExhausted(r, reason == "dispatch_exhausted" && dominance == exhaustedUndecided && failure.StatusCode() == 0)
		// Resolved once: the telemetry event and the OR-uptime counter must agree
		// on which slot's backend this failure belongs to, and on whether that
		// backend was chosen or degraded into (v0.8.0 paged rollout).
		kvBackend := d.exhaustedKVBackendAttribution(failure, stickyFault)
		s.observation.EmitRequest(r.Context(), protocol.SeverityError, d.requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", d.exhaustionAttemptCount(loopResult.LastAttempt)),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     d.exhaustionAttemptCount(loopResult.LastAttempt),
				"status_code": statusCode,
				"last_error":  failure.ErrorText(),
				"kv_backend":  kvBackend.Backend,
			})
		if s.observation.Metrics() != nil {
			s.observation.Metrics().IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "failure"})
		}
		s.observation.Incr("inference.dispatches", []string{"status:failure"})
		// OR-uptime outcome for a dispatched-but-failed request (exactly once;
		// pre-dispatch rejections emit from recordRejection instead).
		d.recordDispatchedRequestOutcome(kvBackend, infermetrics.ClassifyOutcomeByCode(statusCode))
		d.recordRequestOutcomeORView(infermetrics.ClassifyOutcomeByCode(statusCode))
		if statusCode == http.StatusTooManyRequests || statusCode == http.StatusServiceUnavailable {
			retryAfter := s.estimateRetryAfter(d.model)
			if d.lastErrFeasibleAfterMS > 0 {
				// Enriched rejection (routing v2): the rejecting provider
				// forecast when a request of this shape could next be admitted
				// — an honest Retry-After beats the queue-depth heuristic.
				// Clamped to the heuristic's own [2,30]s band so a
				// provider-authored value can neither hammer nor park clients.
				hinted := int((d.lastErrFeasibleAfterMS + 999) / 1000)
				if hinted < 2 {
					hinted = 2
				}
				if hinted > 30 {
					hinted = 30
				}
				retryAfter = hinted
			}
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			info := d.rejectionInfo("dispatch", reason, statusCode, retryAfter*1000)
			if !stickyFault && (d.unservable || failure.Deadline()) {
				// No provider could serve this request (it exceeds the model
				// context, or every attempted provider refused the remaining
				// deadline). Mark it not-servable so the rejection ledger's
				// counterfactual reflects the terminal decision.
				info.Servability.Computed = true
				info.Record.CandidateCount = 0
			}
			s.NewRejectionRecorder().Record(r, info.Record, info.Servability)
		} else {
			info := d.rejectionInfo("dispatch", reason, statusCode, 0)
			s.NewRejectionRecorder().Record(r, info.Record, info.Servability)
		}
		rateLimitMessage := fmt.Sprintf(
			"all providers at capacity after %d attempt(s): %s",
			d.exhaustionAttemptCount(loopResult.LastAttempt), failure.ErrorText())
		if reason == rejectionReasonDeadlineUnreachable {
			rateLimitMessage = fmt.Sprintf(
				"no provider could produce first content within the remaining deadline for model %q",
				d.publicModel)
		}
		if statusCode == http.StatusTooManyRequests {
			httpx.WriteJSON(w, statusCode, httpx.ErrorResponse("rate_limit_exceeded",
				rateLimitMessage, httpx.WithCode("rate_limit_exceeded")))
		} else if d.terminalClientError {
			// Surface the provider's client-shape error verbatim as an
			// invalid_request_error, with no misleading "after N attempt(s)" framing
			// (it was returned once, deterministically). A jinja_* latch surfaces
			// the curated model_capability message instead of the provider's raw
			// template backtrace.
			if d.terminalClientErrorMessage != "" {
				errorCode := "model_capability"
				if d.terminalClientErrorReason == "payload_too_large" {
					errorCode = "payload_too_large"
				}
				httpx.WriteJSON(w, statusCode, httpx.ErrorResponse(
					"invalid_request_error", d.terminalClientErrorMessage, httpx.WithCode(errorCode)))
			} else {
				httpx.WriteJSON(w, statusCode, httpx.ErrorResponse("invalid_request_error", failure.ErrorText()))
			}
		} else {
			httpx.WriteJSON(w, statusCode, httpx.ErrorResponse("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", d.exhaustionAttemptCount(loopResult.LastAttempt), failure.ErrorText())))
		}
		return
	}
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("inference_dispatches_total", observation.MetricLabel{Name: "result", Value: "success"})
	}
	s.observation.Incr("inference.dispatches", []string{"status:success"})
	// OR-uptime outcome. For STREAMING this is a commit-time approximation (the
	// consumer got content; a later post-commit mid-stream failure is still counted
	// as success — the persisted route-outcome rows hold the exact breakdown). For
	// NON-streaming, "committed" only means a provider chunk arrived and the writer
	// can still fail with a 5xx/504, so the outcome is recorded in
	// writeCommittedResponse from the status it actually writes. Emitted exactly
	// once per dispatched request (disjoint from the exhausted branch above and
	// from pre-dispatch rejections).
	if d.stream {
		d.recordDispatchedRequestOutcome(d.kvBackendAttribution(), infermetrics.ORSuccess)
	}

	d.writeCommittedResponse()
}

func (d *dispatchState) writeCommittedResponse() {
	s := d.s
	w, r := d.w, d.r
	provider, pr, requestID := d.provider, d.pr, d.requestID

	// Record the provider responsiveness sample here, in the goroutine that OWNS
	// pr.Timing. handleComplete runs in the provider read-loop goroutine and could
	// race this goroutine's timing writes, so the latency must be recorded from
	// here rather than handed across. d.firstChunk is non-empty only when an actual
	// content chunk was received — a preamble-then-clean-close commits with no
	// content, so FirstContentAt stays zero and no sample is recorded. The
	// prompt-size prefill is removed using the coordinator-side prompt estimate
	// (known up front, adequate for normalization) and the provider's benchmarked
	// PrefillTPS (set once at registration, read-only thereafter).
	if profilepolicy.ShouldRecordReputationLatency(pr, d.firstChunk) {
		// FirstContentAt was already stamped at the content-commit site
		// (commitFirstContent), earlier in THIS goroutine, so contentLatency reads
		// a set value here. No re-stamp needed; just read it for the reputation
		// latency sample.
		sample := profilepolicy.AdjustLatencyForPrefill(profilepolicy.ContentLatency(pr.Timing), pr.EstimatedPromptTokens, provider.PrefillTPS)
		// Provider-level: p.mu only. The registry-level form looks the
		// provider up under r.mu, and this runs before the first client write.
		provider.RecordLatency(sample)
	}

	// Write provider attestation headers now that we're committed. When the
	// caller opted into metadata_details, snapshot the same consumer-safe
	// fields onto the pending request so chat-completions writers can attach
	// them to the JSON body (OpenAI SDKs often hide custom headers).
	info := inresp.CollectCommittedProviderInfo(provider)
	if pr.DispatchVerification.ObservedAt != 0 {
		verification := pr.DispatchVerification
		info.Verification = &verification
	}
	inresp.WriteCommittedProviderHeaders(w, info)
	d.writeTimingHeaderWithProfile(w, pr)
	d.stampCommitted(pr)
	inresp.WriteInferenceJobIDHeader(w, pr.RequestID)
	inresp.SnapshotChatCompletionMetadata(pr, info)

	// On return (disconnect/timeout/completion): free the slot, tell the
	// provider to stop if it may still be generating, and preserve billing for
	// a mid-stream disconnect.
	// Park BEFORE RemovePending so a racing provider terminal always finds the
	// record in pending or the holder — never neither (which would drop it and
	// mis-refund). GetPending is nil if a terminal already settled it (normal
	// completion), so nothing is parked then. Both settle paths are
	// FinalizeReservation-guarded, so the park-then-remove overlap can't double-bill.
	//
	// The cancel is sent only when a pending record still existed — no terminal
	// seen, so the provider may still be running (consumer gone mid-stream, idle
	// stream timeout). After a clean completion or a provider error terminal the
	// record is already gone and a cancel would only cost the provider a no-op
	// frame per request (~one per dispatch fleet-wide before this rule).
	defer func() {
		abandoned := false
		cause := cancellation.CauseStreamTimeout
		if r.Context().Err() != nil {
			cause = cancellation.CauseClientGonePost
		}
		if stale := provider.GetPending(requestID); stale != nil {
			// Record the abandon BEFORE parking so a terminal racing this
			// defer is correlated with the cancel rather than logged as unknown.
			_, expired := s.cancellationController().Tracker.
				Record(requestID, pr.Model, cause, time.Now())
			s.emitExpiredCancelEntries(expired)
			s.holdForSettlement(stale)
			abandoned = true
		} else {
			// A terminal already claimed the pending. In every normal path the
			// reservation is finalized by now (completion billed it, the relay
			// error/timeout branches refunded it) and this is a no-op. The one
			// exception is a provider error landing in the gap between this
			// handler abandoning its channels and this defer running: that
			// terminal pushed into an unread ErrorCh and nobody settled — sweep
			// it here. Post-commit only, so it can never finalize a reservation
			// the dispatch loop still needs for a retry attempt.
			refundPr := pr
			saferun.Go(s.logger, "api.postTerminalSweep", func() {
				s.refundReservedBalance(refundPr, "post_terminal_sweep:"+requestID)
			})
		}
		removed := provider.RemovePending(requestID) // then remove so SetProviderIdle frees the slot
		s.registry.SetProviderIdle(provider.ID)
		if !abandoned {
			return
		}
		if removed == nil {
			s.cancellationController().Tracker.

				// A terminal claimed the record between GetPending and
				// RemovePending: it settles via the parked copy and nothing is
				// running provider-side.
				Forget(requestID)
			return
		}
		// The provider is still generating for a client that is gone: this
		// cancel is the one that stops real work, so stamp it.
		pr.Profile.Mark(registry.StampCancelSent)
		s.sendRecordedCancel(provider, requestID, pr.Model, cause)
	}()

	// The committed provider's held preamble chunks stream out first, in
	// arrival order, ahead of the content chunk that committed the dispatch.
	firstChunks := d.heldChunks
	if d.firstChunk != "" {
		firstChunks = append(firstChunks, d.firstChunk)
	}
	if d.stream {
		s.handleStreamingResponseWithFirstChunkAndError(
			w, r, pr, firstChunks, d.initialError)
	} else {
		// Record the OR-uptime outcome from the status the non-streaming writer
		// actually emits: it can still return a 5xx/504 after commit, and a
		// client-gone exit writes no status (0 → not counted, cancelled is excluded).
		// StatusWriter captures the WriteHeader code and transparently
		// delegates Flush/Hijack/Unwrap, so wrapping preserves the writer's
		// capabilities; zero-valued status starts at 0 (uncounted).
		sw := &httpx.StatusWriter{ResponseWriter: w}
		s.handleNonStreamingResponseWithFirstChunkAndError(
			sw, r, pr, firstChunks, d.initialError)
		switch {
		case sw.Status == http.StatusOK:
			d.recordDispatchedRequestOutcome(d.kvBackendAttribution(), infermetrics.ORSuccess)
		case sw.Status > 0:
			d.recordDispatchedRequestOutcome(
				d.kvBackendAttribution(), infermetrics.ClassifyOutcomeByCode(sw.Status))
		}
	}
}
