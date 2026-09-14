package dispatch

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// dispatchOutcome is the result of a per-attempt dispatch phase (provider
// selection, first-chunk wait, accepted wait). The orchestrator (execution.run)
// switches on it to reproduce the original loop's continue/break/return flow.
type dispatchOutcome int

const (
	// outcomeCommitted: a content chunk (or a clean close) committed the attempt.
	// The orchestrator stops the loop and streams the response.
	outcomeCommitted dispatchOutcome = iota
	// outcomeAccepted: legacy/unstamped preamble liveness earned a bounded
	// content wait. AcceptedCh itself never produces this outcome.
	outcomeAccepted
	// outcomeRetry: the attempt failed (provider error / timeout). Equivalent to
	// the original `continue dispatch` — the orchestrator advances to the next attempt.
	outcomeRetry
	// outcomeFailFast: the loop must stop without a committed provider (e.g.
	// model-too-large, or no-provider on a retry attempt). Equivalent to `break`.
	outcomeFailFast
	// outcomeClientGone: the request context was cancelled; the reservation was
	// already refunded and the handler must return with no response body.
	outcomeClientGone
	// outcomeResponseWritten: a terminal HTTP response was already written
	// (queue rejection / queue timeout / queue insufficient funds 402 etc.) and
	// the handler must return immediately.
	outcomeResponseWritten
	// outcomeProceed: provider selection succeeded; the orchestrator continues
	// to the first-chunk wait for this attempt.
	outcomeProceed
)

type dispatchTerminalFailure struct {
	errText       string
	statusCode    int
	terminalCause string
	deadline      bool
	attribution   dispatchSlotAttribution
}

// execution carries everything the per-request dispatch loop needs. The
// immutable inputs are set once by runDispatch; the mutable fields track the
// in-flight attempt (selected provider, held preamble, commit/accept flags,
// last error for the exhaustion ladder, and the version to steer retries away from).
type execution struct {
	s *Controller

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
	policy                 RoutePolicy
	allowedProviderSerials []string
	cachePlan              registry.CachePlan
	timing                 *registry.RequestTiming
	profile                *registry.RequestProfile
	deadline               time.Duration
	speculativeAt          time.Duration
	// Deterministic test seams for speculative timer/ingress arbitration.
	// Production requests leave both nil.
	onSpeculativeDispatch func()
	onSpeculativeDeferral func()
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
	// genuineFault is request-wide terminal precedence, separate from the
	// lastErr* per-attempt scratch used to persist each attempt's route outcome.
	// Capacity/lifecycle refusals, deadline refusals, neutral typed causes, and
	// deterministic client/model errors never enter this slot.
	genuineFault      *dispatchTerminalFailure
	committed         bool
	lastFailedVersion string
	excludeProviders  map[string]struct{}
	// capacityRetries counts pre-content TRANSIENT-capacity failovers (this
	// node's live KV budget, a full queue, a drain). Bounded by
	// maxCapacityClassRetries so a fleet-wide transient cannot storm; a
	// DETERMINISTIC-context rejection (prompt > model context) stops on the first
	// attempt regardless (see classifyRejection / failoverOutcome).
	capacityRetries int
	// firstChunkTimeoutRetries counts attempts that ended in a
	// coordinator-synthesized first-chunk TIMEOUT (untyped 504 → the
	// "first_chunk_timeout" 429 on exhaustion). Bounded by
	// maxFirstChunkTimeoutRetries so a slow-provider storm cannot burn a
	// fresh fleet scan per attempt across the ladder (the 2026-09-01
	// congestion collapse; see the constant). Each counted attempt was on a
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
	servedKVSlot dispatchSlotAttribution

	// ---- Routing v2 wave-2 plan/hedge state ----
	// plan is the bounded dispatch plan retained by the FIRST full-scan
	// reservation (registry.ReserveProviderWithPlan): up to eight provisional
	// alternates from the same scan that chose the primary. Retries and the
	// speculative backup consume it (ReserveNextFromPlan, then one refresh)
	// before any rescan. nil for queue-path and no-reservation flows —
	// selection behavior is then exactly legacy.
	plan *registry.DispatchPlan
	// planRefreshUsed latches the request's single RefreshDispatchPlan across
	// BOTH consumers (failover retries and the speculative backup). The plan
	// object enforces once-per-plan-chain; this enforces once-per-request.
	planRefreshUsed bool
	// probesLaunched: the one parallel capacity-probe round has started
	// (maybeProbePlanCandidates). One round per request, launched only after
	// the primary frame handoff so probes never add primary latency.
	probesLaunched bool
	// hedgeAdvanceCh delivers the probe round's refined ABSOLUTE speculative
	// launch instant (hedgeLaunchAt) when a confirmed backup's quoted q90
	// proves the 50% point too late to be useful. Buffered 1, written at most
	// once by the quote collector; nil until probes launch. waitFirstChunk
	// consumes at most one value under only-earlier / only-once /
	// never-after-fire guards; without a value the 50% default stands.
	hedgeAdvanceCh chan time.Time
	// hedgeGovernorVerdict is the governor's decision for this request's
	// speculative launch ("" = the governor never ran: no speculative point
	// reached, or an owner-served prefer request). Telemetry/log only.
	hedgeGovernorVerdict string
	// providerDispatches counts inference frames actually handed to a
	// provider — primary, queued, plan-retry, and speculative-backup sends
	// alike, incremented in the write handoff callback that stamps
	// Timing.DispatchedAt. Client-visible exhaustion messages report this
	// machine count; route rows keep the loop index d.attempt untouched.
	providerDispatches int
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
