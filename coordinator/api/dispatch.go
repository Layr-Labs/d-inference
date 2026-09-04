package api

// Per-request dispatch state machine for the consumer inference path.
//
// This file holds the speculative TTFT-aware dispatch loop that handleChatCompletions
// drives: it picks a provider (or queues), waits for the first CONTENT chunk with a
// speculative backup race, fails over invisibly on provider error/timeout up to
// maxDispatchAttempts, and commits exactly once. It is a PURELY STRUCTURAL extraction
// of what previously lived inline in consumer.go — every select arm, timer Stop/Reset,
// channel-close+ErrorCh grace window, heldChunks cap, liveness extension, speculative
// race (backup dispatch / cancel-loser / skipBackup), refund-exactly-once, breaker
// call, DD metric, and status code is preserved exactly.
//
// Control-flow mapping (former labeled blocks → methods):
//
//	for attempt := range maxDispatchAttempts   → dispatchState.run (the orchestrator)
//	dispatch-primary block (incl. queue path)  → dispatchState.dispatchPrimary
//	firstChunkWait + speculative race          → dispatchState.waitFirstChunk
//	  noBackupWait                             →   dispatchState.waitNoBackup
//	  race + sub-waits                         →   dispatchState.runRace
//	    backupFailedPrimaryWait                →     dispatchState.raceBackupFailedWaitPrimary
//	    primaryFailedBackupWait                →     dispatchState.racePrimaryFailedWaitBackup
//	    backupFailedWaitPrimary                →     dispatchState.raceBackupErrWaitPrimary
//	acceptedWait                               → dispatchState.waitAccepted
//
// The former labeled jumps become method returns: `continue dispatch` → outcomeRetry,
// `break`/commit → outcomeCommitted, `break <label>` into the accepted wait →
// outcomeAccepted, `return` (client gone, after refund) → outcomeClientGone, and the
// queue-rejection `writeJSON; return` paths → outcomeResponseWritten. The orchestrator
// switches on the outcome, exactly reproducing the original flow.

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// dispatchOutcome is the result of a per-attempt dispatch phase (provider
// selection, first-chunk wait, accepted wait). The orchestrator (dispatchState.run)
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

// dispatchState carries everything the per-request dispatch loop needs. The
// immutable inputs are set once by runDispatch; the mutable fields track the
// in-flight attempt (selected provider, held preamble, commit/accept flags,
// last error for the exhaustion ladder, and the version to steer retries away from).
type dispatchState struct {
	s *Server

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

// traits builds the routing traits for the current attempt, steering away from
// the most recently failed provider's binary version.
func (d *dispatchState) traits() registry.RequestTraits {
	return registry.RequestTraits{
		HasTools:               d.hasTools,
		RequiresToolConstraint: d.requiresToolConstraint,
		ToolChoiceMode:         d.toolChoiceMode,
		ToolChoiceName:         d.toolChoiceName,
		ParallelToolCalls:      d.parallelToolCalls,
		AvoidVersion:           d.lastFailedVersion,
		MinPrefixCacheProtocol: d.minPrefixCacheProtocol,
	}
}

func (d *dispatchState) configurePending(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.ConsumerEndpoint = d.consumerEndpoint
	pr.RequestedStopSequences = append(
		pr.RequestedStopSequences[:0], d.requestedStopSequences...)
	pr.MetadataDetails = d.metadataDetails
}

func (d *dispatchState) excludedProviderIDs() []string {
	ids := make([]string, 0, len(d.excludeProviders))
	for id := range d.excludeProviders {
		ids = append(ids, id)
	}
	return ids
}

func (d *dispatchState) shouldQueueCompatibleProvider(decision registry.RoutingDecision) bool {
	return d.providerBodyTooLargeErr != "" &&
		d.lastErrCode == http.StatusRequestEntityTooLarge &&
		decision.CapacityRejections > 0
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
	return envEnabledDefaultTrue(envTTFTTerminalReject)
}

// envJinjaTerminalReject is the kill switch for the deterministic
// template-render rejection stop (E4, 2026-07-15 platform errors deep dive).
// A provider error_reason of jinja_channel_tags / jinja_null_bridge /
// jinja_template means the model's chat template could not render the
// request's tool schemas or message history — the same body renders the same
// way on every provider, so failing over is pure waste (prod: 1.57 dispatch
// rows per jinja request, observed up to 17 attempts, 0% eventual success).
// Default true: the ladder stops on the FIRST jinja_* rejection at any
// attempt and surfaces one 422 model_capability invalid_request_error. Set
// =false to restore the legacy fail-over-on-500 behavior. Read live (not a
// Server field) following the envTTFTTerminalReject pattern, so it stays
// confined to this file and is overridable in tests via t.Setenv.
const envJinjaTerminalReject = "EIGENINFERENCE_JINJA_TERMINAL_REJECT"

// jinjaTerminalRejectEnabled reports whether a jinja_* provider rejection
// terminates the dispatch ladder. Default true.
func jinjaTerminalRejectEnabled() bool {
	return envEnabledDefaultTrue(envJinjaTerminalReject)
}

// jinjaTerminalRejectMessage is the OpenAI-style error body surfaced for a
// latched template-render failure — a curated model_capability message
// instead of the provider's raw Jinja backtrace (which names filters and
// template internals no API consumer can act on).
const jinjaTerminalRejectMessage = "the request's tool schemas or message history cannot be rendered by this model's chat template; simplify the tool parameter schemas or message structure, or use a different model"

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
	if policy.enabled || policy.prefer {
		return 0
	}
	if !hardReject {
		return 0
	}
	return float64(deadline.Milliseconds())
}

// routingOutcomeKey returns a stable requestID + attempt identifier used for
// telemetry updates. It prefers the explicit dispatch requestID, falling back
// to the pending request's ID when the dispatch requestID has not been set yet.
func (d *dispatchState) routingOutcomeKey() string {
	if d.requestID != "" {
		return d.requestID
	}
	if d.pr != nil {
		return d.pr.RequestID
	}
	return ""
}

// recordRoutingDecision writes a best-effort snapshot of the scheduler decision
// for the current attempt. It never blocks inference.
func (d *dispatchState) recordRoutingDecision(decision registry.RoutingDecision, dispatchErr, outcomeOverride string) {
	d.recordRoutingDecisionFor(d.provider, d.pr, d.routingOutcomeKey(), d.attempt, decision, dispatchErr, outcomeOverride)
}

func (d *dispatchState) recordRoutingDecisionFor(provider *registry.Provider, pr *registry.PendingRequest, requestID string, attempt int, decision registry.RoutingDecision, dispatchErr, outcomeOverride string) {
	s := d.s
	if requestID == "" && pr != nil {
		requestID = pr.RequestID
	}

	providerID := ""
	if provider != nil {
		providerID = provider.ID
	} else if decision.ProviderID != "" {
		providerID = decision.ProviderID
	}

	outcome := outcomeOverride
	if outcome == "" {
		switch {
		case providerID != "":
			outcome = "selected"
		case dispatchErr == errModelTooLarge:
			outcome = "model_too_large"
		case dispatchErr == errTTFTTooSlow:
			outcome = "ttft_429"
		case dispatchErr == "no provider available":
			outcome = "no_provider"
		default:
			outcome = "error"
		}
	}

	keyID := ""
	if pr != nil {
		keyID = pr.KeyID
	}

	record := &store.InferenceRouteRecord{
		RequestID:               requestID,
		Attempt:                 attempt,
		ProviderID:              providerID,
		Model:                   d.model,
		PublicModel:             d.publicModel,
		ConsumerKeyHash:         store.HashKey(d.consumerKey),
		KeyID:                   keyID,
		Outcome:                 outcome,
		CostMs:                  decision.CostMs,
		StateMs:                 decision.StateMs,
		QueueMs:                 decision.QueueMs,
		PendingMs:               decision.PendingMs,
		BacklogMs:               decision.BacklogMs,
		ThisReqMs:               decision.ThisReqMs,
		HealthMs:                decision.HealthMs,
		TTFTMs:                  decision.TTFTMs,
		BestTTFTMs:              decision.BestTTFTMs,
		EffectiveQueue:          decision.EffectiveQueue,
		CandidateCount:          decision.CandidateCount,
		CapacityRejections:      decision.CapacityRejections,
		ModelTooLargeRejections: decision.ModelTooLargeRejections,
		VisionRejections:        decision.VisionRejections,
		TTFTRejections:          decision.TTFTRejections,
		EffectiveTPS:            decision.EffectiveTPS,
		StaticTPS:               decision.StaticTPS,
		EstimatedPromptTokens:   d.estimatedPromptTokens,
		RequestedMaxTokens:      d.requestedMaxTokens,
		RequiresVision:          d.requiresVision,
		HasTools:                d.hasTools,
		SelfRouteOnly:           d.policy.enabled,
		PreferOwner:             d.policy.prefer,
		CreatedAt:               time.Now(),
		UpdatedAt:               time.Now(),
	}

	if provider != nil {
		provider.Mu().Lock()
		record.ProviderStatus = string(provider.Status)
		record.ProviderTrustLevel = string(provider.TrustLevel)
		record.ProviderVersion = provider.Version
		record.HardwareChip = provider.Hardware.ChipName
		record.HardwareChipFamily = provider.Hardware.ChipFamily
		record.HardwareTier = provider.Hardware.ChipTier
		record.MemoryGB = provider.Hardware.MemoryGB
		record.GPUCores = provider.Hardware.GPUCores
		record.CPUCores = provider.Hardware.CPUCores.Total
		record.SystemMemoryPressure = provider.SystemMetrics.MemoryPressure
		record.SystemCPUUsage = provider.SystemMetrics.CPUUsage
		record.SystemThermalState = provider.SystemMetrics.ThermalState
		if cap := provider.BackendCapacity; cap != nil {
			record.GPUMemoryActiveGB = cap.GPUMemoryActiveGB
			record.GPUMemoryPeakGB = cap.GPUMemoryPeakGB
			record.GPUMemoryCacheGB = cap.GPUMemoryCacheGB
			for _, slot := range cap.Slots {
				if slot.Model == d.model {
					record.SlotState = slot.State
					record.BackendRunning = slot.NumRunning
					record.BackendWaiting = slot.NumWaiting
					record.ActiveTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					record.ActiveTokenBudgetMax = slot.ActiveTokenBudgetMax
					record.QueuedTokenBudget = slot.QueuedTokenBudget
					break
				}
			}
		}
		provider.Mu().Unlock()
	}

	// Phase-0 shadow TTFT admission/spread metrics. No-op unless the request was
	// evaluated (admission mode != off AND a provider was selected). Emitted on
	// the synchronous path (cheap counter incr), not inside the async store write.
	s.emitTTFTShadowMetrics(d.model, decision)
	if decision.CacheDiscountMs > 0 {
		s.ddIncr("routing.cache_evaluation", []string{
			"mode:active",
			"tier:" + lowCardinalityCacheTier(decision.CacheTier),
		})
	}

	s.submitTelemetry("recordInferenceRoute", func() {
		if err := s.store.RecordInferenceRoute(record); err != nil && s.logger != nil {
			s.logger.Error("inference_routes record write failed",
				"request_id", record.RequestID,
				"attempt", record.Attempt,
				"provider_id", record.ProviderID,
				"model", record.Model,
				"error", err,
			)
		}
	})
}

// timingMsBetween returns the elapsed milliseconds between two request-lifecycle
// timestamps, or 0 when either endpoint is unset or the interval is non-positive.
// It keeps the latency-decomposition fields defensive: never a negative value,
// never a panic on a zero timestamp.
func timingMsBetween(a, b time.Time) float64 {
	if a.IsZero() || b.IsZero() || !b.After(a) {
		return 0
	}
	return float64(b.Sub(a).Milliseconds())
}

// applyTimingDecomposition fills the coordinator-side latency-decomposition
// fields (ParseMs..DispatchMs) on a routing outcome from the per-request timing
// stamps. Each segment is populated only when both of its endpoints are set
// (timingMsBetween returns 0 otherwise), so a partially-instrumented request
// never records a negative or bogus segment. QueueWaitMs is 0 for requests that
// were dispatched without queueing (QueuedAt unset).
//
// firstChunk is passed in (not read from t.FirstChunkAt) so this can also be
// called from the provider read-loop goroutine (handleComplete) with a value
// obtained via PendingRequest.FirstChunkAtSafe; t.FirstChunkAt itself must only
// be read directly by the dispatch goroutine that owns the request.
func applyTimingDecomposition(out *store.InferenceRouteOutcome, t *registry.RequestTiming, firstChunk time.Time) {
	if out == nil || t == nil {
		return
	}
	out.ParseMs = timingMsBetween(t.ReceivedAt, t.ParsedAt)
	out.ReserveMs = timingMsBetween(t.ParsedAt, t.ReservedAt)
	// Remote-media fetch (when it happened) sits between ReservedAt and
	// RoutedAt; anchor the route segment past it so a multi-second download
	// doesn't masquerade as routing latency. The fetch duration itself is
	// reported via the X-Timing header and DD histogram (no outcome column).
	routeAnchor := t.ReservedAt
	if !t.MediaFetchedAt.IsZero() {
		routeAnchor = t.MediaFetchedAt
	}
	out.RouteMs = timingMsBetween(routeAnchor, t.RoutedAt)
	out.EncryptMs = timingMsBetween(t.RoutedAt, t.EncryptedAt)
	out.QueueWaitMs = timingMsBetween(t.QueuedAt, t.DispatchedAt)
	out.DispatchMs = timingMsBetween(t.DispatchedAt, firstChunk)
}

// commitFirstContent records the first CONTENT chunk on the committed attempt and
// stamps FirstContentAt (the actual_ttft_ms anchor) in the SAME instant, on the
// dispatch goroutine that reads the chunk. Stamping HERE — rather than later in
// writeCommittedResponse — guarantees FirstContentAt is set before ANY route
// outcome is built for this attempt: the committed/success outcome written by
// this goroutine (e.g. waitFirstChunk / waitAccepted's defer) AND the terminal
// completeRouteOutcome written concurrently by handleComplete on the provider
// read-loop. Without it a fast single-chunk completion could persist
// actual_ttft_ms as 0/NULL (applyPendingRouteTelemetry derives it solely from
// FirstContentAt). pr is the COMMITTED attempt — the backup on a speculative
// backup win, the primary otherwise. MarkFirstChunkArrived is kept (idempotent:
// it preserves an earlier preamble's first-byte time for dispatch_to_first_chunk_ms).
func (d *dispatchState) commitFirstContent(pr *registry.PendingRequest, chunk string) {
	d.firstChunk = chunk
	pr.MarkFirstChunkArrived()
	pr.MarkFirstContentArrived()
	d.stampFirstContent(pr)
	// Mark THIS attempt as the committed one so handleComplete's fallback only
	// ever stamps FirstContentAt for the attempt that actually delivered content —
	// never a late-completing abandoned/retried attempt sharing the same Timing.
	pr.MarkContentCommitted()
	d.s.observeTTFTCalibration(pr)
	// First CONTENT chunk == the provider ACCEPTED and is serving: clear the
	// pair's capacity-reject streak NOW rather than at completion. A long
	// generation on a busy box must keep vouching for the pair while the box
	// legitimately sheds concurrent dispatches — waiting for the completion
	// accept (noteInferenceSuccess) would let transient fullness masquerade as
	// the zero-accepts black-hole signature. See registry/capacity_cooldown.go.
	//
	// The recorder takes the registry WRITE lock, which in production waits
	// behind every queued writer (~190 ms at the median, seconds at the tail),
	// and this runs BEFORE the chunk is written to the client. It is pure
	// bookkeeping, so it runs off this goroutine and the first byte no longer
	// waits for it. Exactly-once for the capacity-503 RATE window is kept by
	// stamping the request BEFORE the recorder runs: the completion-time
	// re-offer (noteInferenceSuccess) fires only for an unstamped request, and
	// the recorder declines to store an offered accept only when rate tracking
	// is disabled (PenaltyMs <= 0) — in which case the completion re-offer
	// would store nothing either. So the unconditional stamp never loses an
	// outcome and never double counts.
	pr.MarkRateOutcomeCounted()
	providerID, model := pr.ProviderID, pr.Model
	saferun.Go(d.s.logger, "api.recordCapacityAccept", func() {
		d.s.registry.RecordCapacityAccept(providerID, model)
	})
}

func (d *dispatchState) successRoutingOutcomeFor(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return committedRouteOutcome(pr)
}

// errorRoutingOutcome builds an error / timeout / cancelled outcome.
func (d *dispatchState) errorRoutingOutcome(status, class string, code int) *store.InferenceRouteOutcome {
	return d.errorRoutingOutcomeFor(d.pr, status, class, code)
}

func (d *dispatchState) errorRoutingOutcomeFor(pr *registry.PendingRequest, status, class string, code int) *store.InferenceRouteOutcome {
	providerReason, errorText := "", ""
	if routeOutcomeUsesProviderErrorText(class) {
		providerReason = d.lastErrReason
		errorText = d.lastErr
	}
	out := routeOutcomeWithReason(status, class, code, providerReason, errorText)
	applyPendingRouteTelemetry(out, pr)
	return out
}

func (d *dispatchState) recordProviderBodyTooLargeRoute(
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
) {
	if provider == nil || pr == nil {
		return
	}
	d.recordRoutingDecisionFor(
		provider, pr, pr.RequestID, pr.Attempt, decision, "", "")
	d.s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(
		pr, errorClassClientError, http.StatusRequestEntityTooLarge))
}

func routeOutcomeUsesProviderErrorText(class string) bool {
	class = strings.ToLower(strings.TrimSpace(class))
	return class == errorReasonProviderError ||
		class == errorClassDeadlineUnreachable ||
		// client_error rows keep the provider-supplied reason too: a jinja_*
		// template-render failure is recorded as class client_error (not a
		// provider fault) but its reason must stay jinja_* on the row, so the
		// inference.error{reason:jinja_*} series measures real render failures
		// instead of being silenced by the reclassification. The reason is
		// still whitelisted downstream (normalizeInferenceErrorReason).
		class == errorClassClientError ||
		strings.HasPrefix(class, "provider_error") ||
		strings.HasPrefix(class, "provider_disconnect") ||
		strings.Contains(class, "provider_incomplete")
}

func (d *dispatchState) setLastError(errText string, statusCode int) {
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
	if isProviderHealthNeutralErrorReason(msg.ErrorReason) {
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
	switch class, _ := classifyTerminalCause(msg.TerminalCause); class {
	case causeClassNeutral, causeClassCapacity:
		return false
	case causeClassFault:
		return true
	}
	return classifyRejection(
		msg.ErrorReason, msg.Error, providerBudget, modelContext,
		msg.RejectionReason,
	) == rejectionNotCapacity
}

func terminalFailureFromMessage(msg protocol.InferenceErrorMessage) dispatchTerminalFailure {
	return dispatchTerminalFailure{
		errText:       msg.Error,
		statusCode:    msg.StatusCode,
		terminalCause: msg.TerminalCause,
		deadline:      isDeadlineUnreachableErrorReason(msg.ErrorReason),
	}
}

func (d *dispatchState) captureGenuineFault(
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

func (d *dispatchState) currentTerminalFailure() dispatchTerminalFailure {
	return dispatchTerminalFailure{
		errText:       d.lastErr,
		statusCode:    d.lastErrCode,
		terminalCause: d.lastErrTerminalCause,
		deadline:      d.lastFailureDeadline,
	}
}

func (d *dispatchState) terminalFailureForExhaustion() (
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
	if statusCode == http.StatusGatewayTimeout && !isTypedTimeout504Cause(terminalCause) {
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

func (d *dispatchState) resolveDominantExhaustedStatus(
	failure dispatchTerminalFailure,
	stickyFault bool,
) (statusCode int, reason string, timeoutReclassified bool, dominance exhaustedDominance) {
	statusCode, reason, timeoutReclassified = classifyExhaustedStatus(
		failure.statusCode, failure.terminalCause)
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

func (d *dispatchState) noteProviderBodyTooLarge(errText string, bodyBytes int) {
	d.providerBodyTooLargeErr = errText
	d.providerBodyTooLargeBytes = bodyBytes
	d.setLastError(errText, http.StatusRequestEntityTooLarge)
}

func (d *dispatchState) preflightLegacyCacheBust() {
	_, err := minimumLegacyCacheBustOverflow(d.rawBody, d.requiresVision)
	if errors.Is(err, errProviderBodyTooLarge) {
		d.minPrefixCacheProtocol = 1
	}
}

func (d *dispatchState) noteProviderBodyTooLargeFor(
	provider *registry.Provider,
	errText string,
) {
	if provider == nil {
		return
	}
	if d.excludeProviders == nil {
		d.excludeProviders = make(map[string]struct{})
	}
	d.excludeProviders[provider.ID] = struct{}{}
	bodyBytes, _ := providerBodySizeError(
		d.rawBody, d.requiresVision, provider)
	d.noteProviderBodyTooLarge(errText, bodyBytes)
}

func (d *dispatchState) latchProviderBodyTooLarge(errText string) {
	d.noteProviderBodyTooLarge(errText, d.providerBodyTooLargeBytes)
	d.terminalClientError = true
	d.terminalClientErrorCode = http.StatusRequestEntityTooLarge
	d.terminalClientErrorReason = "payload_too_large"
	d.terminalClientErrorMessage = errText
}

// setLastInferenceError records a pre-content provider rejection as the dispatch
// loop's last error and snapshots the rejecting provider's reported token budget
// for d.model. shouldStopFailover needs that budget to tell a fleet-wide
// DETERMINISTIC context overflow apart from THIS node's memory-pressured KV budget
// (see classifyRejection). provider may be nil (budget 0 = unknown).
func (d *dispatchState) setLastInferenceError(provider *registry.Provider, msg protocol.InferenceErrorMessage) {
	msg = normalizeInferenceErrorForInternalUse(msg)
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
	d.lastFailureDeadline = isDeadlineUnreachableErrorReason(msg.ErrorReason)
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

// providerFailedRoutingOutcome builds the outcome for a POST-DISPATCH provider
// failure: the request had already been admitted to a specific provider (passed
// the admission gate and was dispatched over the WebSocket) and that provider
// then reported an error — including provider-reported OOM / model-load failures
// that surface on pr.ErrorCh. It flags AdmittedButFailed to expose the
// admission-gate mismatch (coordinator said "this provider can serve" but it
// could not). It is intentionally only used from the post-dispatch wait loops;
// pre-dispatch failures (queue reservation DB error, invalid key, keygen, send
// failure) and coordinator-side timeouts are NOT flagged.
func (d *dispatchState) providerFailedRoutingOutcome() *store.InferenceRouteOutcome {
	return d.providerFailedRoutingOutcomeFor(d.pr)
}

func (d *dispatchState) providerFailedRoutingOutcomeFor(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	if isDeadlineUnreachableErrorReason(d.lastErrReason) {
		// The provider declined work before execution because the coordinator's
		// remaining absolute budget could not be met. Preserve the typed reason
		// without marking the provider as admitted-but-failed.
		out := d.errorRoutingOutcomeFor(
			pr, "error", errorClassDeadlineUnreachable, d.lastErrCode)
		applyAttemptUsage(out, d.lastErrAttemptUsage)
		return out
	}
	if isTerminalClientErrorCode(d.lastErrCode) || isNonProviderFaultErrorReason(d.lastErrReason) {
		// Deterministic non-provider fault: a 4xx status the provider maps for
		// malformed bodies, OR a structured non-provider-fault reason (jinja_*
		// template-render failures, tool_noncompliance model-output 422s).
		// Record as client_error WITHOUT AdmittedButFailed so neither pollutes
		// the admission-mismatch gauge — keyed on the SAME vocabulary as the
		// reputation and breaker exemptions (isNonProviderFaultErrorReason).
		// The structured reason survives on the row (see
		// routeOutcomeUsesProviderErrorText). Typed partial usage (if any)
		// still lands on the row — observability only, no billing effect.
		out := d.errorRoutingOutcomeFor(pr, "error", errorClassClientError, d.lastErrCode)
		applyAttemptUsage(out, d.lastErrAttemptUsage)
		return out
	}
	class := "provider_error"
	if d.lastErrCoordinatorCause == protocol.CoordinatorCauseProviderDisconnected {
		class = "provider_disconnect_pre_commit"
	}
	out := d.errorRoutingOutcomeFor(pr, "error", class, d.lastErrCode)
	out.AdmittedButFailed = true
	// Pre-content typed failures on the ordinary dispatch path flow through
	// the deferred route update via this builder (not the standalone
	// preResponse/postCommit constructors), so the typed attempt_usage
	// retained by setLastInferenceError must be applied here too or the row
	// records null token counts for the most common failure path.
	applyAttemptUsage(out, d.lastErrAttemptUsage)
	return out
}

// isTerminalClientErrorCode reports whether a provider-returned status code is a
// DETERMINISTIC client-shape rejection that fails identically on every provider,
// so the dispatch loop must stop and return it ONCE rather than fail over.
//
// Set: 400 (invalidRole / invalidToolPayload / mediaUnsupportedByModel + all VLM
// client MediaError), plus 413/415 defensively (unambiguous client shapes; not
// emitted by the provider map today but correct if a future version does).
//
// EXCLUDES 422 deliberately: the provider maps invalidResponseFormatOutput→422,
// which is thrown for BOTH a deterministic request-shape fault ("json_schema
// requires a json_schema payload") AND a model-OUTPUT-validation fault ("model
// output was not valid JSON"). The latter depends on what the model GENERATED, so
// a re-sample at temperature>0 (or a different provider/model) could succeed —
// stopping it would turn a recoverable request into a lost success (hurting
// uptime). 422 therefore stays on the normal failover path.
//
// Also EXCLUDES 404 ("model not loaded" — a cold-miss/lifecycle that MUST fail
// over, and which matches the "not loaded" capacity marker), 408 and 429
// (transient). 402 (the only coordinator-emitted 4xx) is excluded, so a code in
// this set can ONLY originate from a provider InferenceErrorMessage.
func isTerminalClientErrorCode(code int) bool {
	switch code {
	case http.StatusBadRequest, // 400
		http.StatusRequestEntityTooLarge, // 413
		http.StatusUnsupportedMediaType:  // 415
		return true
	}
	return false
}

func dispatchErrorClass(errText string) string {
	if strings.Contains(errText, errProviderBodyTooLarge.Error()) {
		return errorClassClientError
	}
	switch errText {
	case "insufficient funds for provider price":
		return "insufficient_funds"
	case "no provider with E2E encryption":
		return "encryption_missing"
	case "provider public key invalid", "failed to encrypt request", "failed to generate session keys", "failed to marshal request":
		return "encryption_error"
	case errFirstContentDeadlineExpired:
		return "first_chunk_timeout"
	case "failed to send request to provider":
		return "provider_error"
	default:
		if errText == "" {
			return "provider_error"
		}
		return "provider_error"
	}
}

// queuedExitOutcome records the terminal route outcome of a queue-wait exit
// and mirrors its status/reason onto the placeholder attempt profile. While
// the request waits, d.pr is nil, so updateRoutingOutcome takes the request-id
// path and never reaches the attempt profile; the pair is written here, in one
// place, so the row and the profile cannot drift. It is deliberately NOT
// routed through updateInferenceRouteOutcomeForPending, which would also fire
// the cache-selection terminal for a request that never had a provider.
func (d *dispatchState) queuedExitOutcome(ap *registry.AttemptProfile, status, reason string, code int) {
	d.updateRoutingOutcome(d.errorRoutingOutcome(status, reason, code))
	ap.SetOutcome(status, reason, "", "", "")
}

// closeQueuedAttempt closes the queue-path placeholder attempt when it never
// reached the wire (closeUndispatchedAttempt is a no-op for a dispatched or
// winning attempt), recording the error the failing branch left on d.
//
// AttemptProfile.SetOutcome is first-write-wins, and every queue-path exit
// has already written its final_status/error_reason on the placeholder by the
// time this runs: the pre-assignment exits (queue full, client gone, deadline,
// ttft_too_slow, tool constraint, queue timeout) write it explicitly
// (queuedExitOutcome / the queue-full SetOutcome), and the post-assignment
// exits (top-up, key, encrypt, writer timeout, write error) write it through
// the pending route-outcome funnel because d.pr is set by then. This close
// therefore contributes provider_outcome=not_dispatched, and its own
// status/class only as a fallback for an exit that recorded nothing. A status
// code of 0 means the branch had no HTTP status: the code is defaulted by how
// the wait ended, but the text only when nothing was recorded, so a real error
// text with no code (e.g. "no provider with E2E encryption") keeps its own
// class instead of collapsing to queue_rejected.
func (d *dispatchState) closeQueuedAttempt(ap *registry.AttemptProfile) {
	errText, code := d.lastErr, d.lastErrCode
	if code == 0 {
		clientGone := d.r != nil && d.r.Context().Err() != nil
		if clientGone {
			code = 499
		} else {
			code = http.StatusTooManyRequests
		}
		if errText == "" {
			if clientGone {
				errText = "client_gone"
			} else {
				errText = "queue_rejected"
			}
		}
	}
	closeUndispatchedAttempt(ap, errText, code)
}

func (d *dispatchState) rejectionInfo(stage, reason string, status, retryAfterMs int) rejectionInfo {
	info := rejectionInfo{
		r:                     d.r,
		stage:                 stage,
		reasonCode:            reason,
		httpStatus:            status,
		keyID:                 keyIDFromContext(d.r.Context()),
		consumerKeyHash:       store.HashKey(d.consumerKey),
		requestedModel:        d.publicModel,
		resolvedModel:         d.model,
		stream:                d.stream,
		estimatedPromptTokens: d.estimatedPromptTokens,
		requestedMaxTokens:    d.requestedMaxTokens,
		requiresVision:        d.requiresVision,
		hasTools:              d.hasTools,
		selfRouteOnly:         d.policy.enabled,
		preferOwner:           d.policy.prefer,
		retryAfterMs:          retryAfterMs,
	}
	if reason == "payload_too_large" {
		info.servabilityComputed = true
		if d.providerBodyTooLargeBytes > 0 {
			info.requestBodyBytes = d.providerBodyTooLargeBytes
		}
	}
	return info
}

func (d *dispatchState) rejectionInfoWithDecision(stage, reason string, status, retryAfterMs int, decision registry.RoutingDecision) rejectionInfo {
	info := d.rejectionInfo(stage, reason, status, retryAfterMs)
	info.servabilityComputed = true
	info.candidateCount = decision.CandidateCount
	info.capacityRejections = decision.CapacityRejections
	info.modelTooLargeRejections = decision.ModelTooLargeRejections
	info.visionRejections = decision.VisionRejections
	info.bestTTFTMs = decision.BestTTFTMs
	return info
}

// dispatchRoutingAttempt is immutable identity captured before a wait path can
// clear or promote mutable dispatchState provider/request fields.
type dispatchRoutingAttempt struct {
	provider  *registry.Provider
	pending   *registry.PendingRequest
	requestID string
	attempt   int
}

func routingAttempt(provider *registry.Provider, pr *registry.PendingRequest, requestID string, attempt int) dispatchRoutingAttempt {
	return dispatchRoutingAttempt{provider: provider, pending: pr, requestID: requestID, attempt: attempt}
}

func (d *dispatchState) currentOrCapturedRoutingAttempt(captured dispatchRoutingAttempt) dispatchRoutingAttempt {
	if d.pr == nil {
		// A cleared request ID is an intentional no-op sentinel: speculative
		// sub-waits clear all three fields after recording each racer's terminal
		// outcome themselves. Restoring captured here would attribute the
		// surviving racer's later failure or timeout to the already-finalized
		// primary. Ordinary single-attempt fallbacks retain requestID and still
		// use captured below.
		if d.requestID == "" {
			return dispatchRoutingAttempt{}
		}
		return captured
	}
	return routingAttempt(d.provider, d.pr, d.routingOutcomeKey(), d.attempt)
}

func (d *dispatchState) updateRoutingOutcomeForAttempt(target dispatchRoutingAttempt, outcome *store.InferenceRouteOutcome) {
	requestID, attempt := target.requestID, target.attempt
	if requestID == "" {
		return
	}
	providerMatches := target.provider == nil ||
		(target.pending != nil && target.pending.ProviderID != "" && target.pending.ProviderID == target.provider.ID)
	if target.pending != nil && target.pending.RequestID == requestID && target.pending.Attempt == attempt && providerMatches {
		d.s.updateInferenceRouteOutcomeForPending(target.pending, outcome)
		return
	}
	d.s.updateInferenceRouteOutcomeWithModel(requestID, attempt, d.model, outcome)
}

// updateRoutingOutcome writes an outcome update for the current attempt. It is
// a no-op when there is no request ID to correlate.
func (d *dispatchState) updateRoutingOutcome(outcome *store.InferenceRouteOutcome) {
	requestID := d.routingOutcomeKey()
	if requestID == "" {
		return
	}
	// Capture attempt on the dispatch goroutine: the closure runs on a telemetry
	// sink worker, while run()'s retry loop concurrently advances d.attempt.
	attempt := d.attempt
	d.updateRoutingOutcomeForAttempt(routingAttempt(d.provider, d.pr, requestID, attempt), outcome)
}

func (d *dispatchState) markSpeculativeLoser(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.UsedBackup = true
	d.s.updateInferenceRouteOutcomeForPending(pr, speculativeLoserOutcome(pr))
}

func (d *dispatchState) updateSpeculativeFailure(pr *registry.PendingRequest, msg protocol.InferenceErrorMessage) {
	if pr == nil {
		return
	}
	pr.UsedBackup = true
	d.s.updateInferenceRouteOutcomeForPending(pr, preCommitProviderErrorOutcome(pr, msg))
}

func (d *dispatchState) updateSpeculativeTimeout(pr *registry.PendingRequest, class string) {
	if pr == nil {
		return
	}
	pr.UsedBackup = true
	d.s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "timeout", class, http.StatusGatewayTimeout))
}

func (d *dispatchState) updateSpeculativeClientGone(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.UsedBackup = true
	d.s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "cancelled", "client_gone", 0))
}

// emitClientGone records a before-first-token cancellation on the
// d_inference.routing.client_gone counter for this attempt. It reads
// the current candidate's chip family (or "unknown" when no provider is selected
// yet, e.g. a queue-wait cancel) and the estimated prompt-token bucket. Called
// once per logical client_gone at the central classification sites so speculative
// backup bookkeeping (updateSpeculativeClientGone) never double-counts.
func (d *dispatchState) emitClientGone(phase string) {
	d.stampClientGone(phase)
	d.s.emitClientGone(d.model, d.estimatedPromptTokens, providerChipFamily(d.provider), phase)
}

// dispatchPrimary selects (and, when no idle provider exists on the first
// attempt, queues + dispatches) the primary provider for this attempt. It is the
// extraction of the original loop's dispatch-primary block (incl. the queue path).
// On success it leaves d.provider/d.pr set and returns outcomeProceed.
func (d *dispatchState) dispatchPrimary() dispatchOutcome {
	s := d.s
	r, w := d.r, d.w
	attempt := d.attempt

	// Dispatch the primary provider.
	var dispatchErr string
	var dispatchErrCode int
	var decision registry.RoutingDecision
	routeRecorded := false
	routeRequestID := ""
	routeAttempt := attempt
	var routeProvider *registry.Provider
	recordRoute := func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
		routeProvider = provider
		routeRecorded = true
		if pr != nil {
			d.configurePending(pr)
			routeRequestID = pr.RequestID
			routeAttempt = pr.Attempt
		}
		d.recordRoutingDecisionFor(provider, pr, routeRequestID, routeAttempt, decision, "", "")
	}
	// Routing v2 W2: retry attempts consume the retained plan — the next
	// revalidated entry, then the request's single refresh — BEFORE any full
	// rescan (identity retention; the rescan herd is the failure the plan
	// exists to end). The machinery only changes WHERE the next provider
	// comes from: when it yields nothing, the legacy scan below runs
	// unchanged, keeping every terminal classification (model_too_large,
	// ttft_too_slow, queueing) byte-identical.
	planTried := false
	if attempt > 0 {
		d.provider, d.pr, decision, dispatchErr, dispatchErrCode, planTried =
			d.dispatchFromPlanMachinery(d.timing, d.excludeProviders, "", recordRoute)
	}
	if !planTried {
		var plan *registry.DispatchPlan
		d.provider, d.pr, decision, plan, dispatchErr, dispatchErrCode = s.dispatchOneProvider(
			r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
			d.estimatedPromptTokens, d.deadline, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
			d.traits(),
			d.allowedProviderSerials, d.isResponsesAPI, d.policy, d.timing, d.serviceReservation, d.cachePlan, d.excludeProviders,
			d.attempt, d.profile, "",
			recordRoute,
			d.noteProviderDispatched,
		)
		if d.plan == nil {
			// Adopt the FIRST retained plan only. Once the plan chain
			// (entries + one refresh) is spent, later fallback scans stay
			// pure legacy — adopting their plans would resurrect the
			// machinery past its bounded refresh.
			d.plan = plan
		}
	}
	d.dispatchErr = dispatchErr
	d.dispatchErrCode = dispatchErrCode
	if !routeRecorded {
		d.recordRoutingDecision(decision, dispatchErr, "")
	}
	if d.provider == nil {
		if dispatchErrCode == http.StatusRequestEntityTooLarge {
			d.noteProviderBodyTooLargeFor(routeProvider, dispatchErr)
		}
		if routeRecorded {
			d.s.updateInferenceRouteOutcomeWithModel(routeRequestID, routeAttempt, d.model, d.errorRoutingOutcome("error", dispatchErrorClass(dispatchErr), dispatchErrCode))
		}
		// No online provider has enough memory to ever fit this model.
		// Retrying and queueing are both pointless — reject immediately
		// with a clear, non-retryable error.
		if dispatchErr == errModelTooLarge {
			s.ddIncr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model), "outcome:model_too_large"})
			d.setLastError(dispatchErr, dispatchErrCode)
			return outcomeFailFast
		}
		if dispatchErrCode == http.StatusRequestEntityTooLarge {
			return outcomeRetry
		}
		if dispatchErr == errFirstContentDeadlineExpired {
			// The request clock expired before the selected frame reached the
			// wire. This is coordinator-owned deadline exhaustion, not a
			// provider send fault, and another attempt cannot regain time.
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			return outcomeFailFast
		}
		if dispatchErr == errClientGoneBeforeScan {
			// The caller's context fired while parked for a scan slot. Mirror
			// the queue-wait cancellation arm exactly: cancelled route
			// outcome, refund, no response body — NEVER the routing_saturated
			// 429 or a rejection-ledger row (the client is not retrying; the
			// ledger must not count a shed that never happened).
			d.emitClientGone(phaseBeforeFirstToken)
			d.updateRoutingOutcome(d.errorRoutingOutcome("cancelled", "client_gone", 0))
			d.refundReservation()
			return outcomeClientGone
		}
		if dispatchErr == errRoutingScanSaturated {
			// No provider-selection scan slot freed up within the request's
			// whole remaining first-content budget — the coordinator itself is
			// saturated (2026-09-01 collapse). Zero providers were scanned or
			// contacted, so latch the capacity-shaped verdict: the exhausted
			// ladder emits ONE uptime-neutral retryable 429 (whose Retry-After
			// scales with the route-latency distress EWMA) and never scans
			// again for this request.
			s.ddIncr("routing.scan_admission_timeout", []string{"model:" + d.model})
			d.setLastError(dispatchErr, http.StatusTooManyRequests)
			d.unservable = true
			d.unservableReason = rejectionReasonRoutingSaturated
			return outcomeFailFast
		}
		if d.lastFailureDeadline && dispatchErr == errTTFTTooSlow {
			// At least one provider already refused this exact remaining
			// deadline, and the rest cannot pass hard TTFT admission. Candidate
			// exhaustion belongs to the deadline_unreachable terminal below,
			// not a fresh ttft_too_slow response that hides the refusal.
			return outcomeFailFast
		}

		// Providers are available but all exceed the TTFT ceiling. This
		// rejection is deterministic — the scheduler computes it from the same
		// fleet-wide estimate on every scan — so retrying the reservation
		// within this request cannot succeed. Fail fast with a retryable 429
		// on ANY attempt (kill switch: EIGENINFERENCE_TTFT_TERMINAL_REJECT=
		// false restores the legacy attempt-0-only fast path, under which a
		// mid-ladder rejection looped to maxDispatchAttempts re-running the
		// doomed scan). Deferred HTTP commitment guarantees this rejection can
		// still carry its correct status.
		if dispatchErr == errTTFTTooSlow && (attempt == 0 || ttftTerminalRejectEnabled()) {
			bestTTFT := time.Duration(decision.BestTTFTMs * float64(time.Millisecond))
			d.refundReservation()
			if attempt > 0 {
				// The legacy loop's exhausted ladder wrote ONE request_rejections
				// row and ONE OR-uptime outcome for a mid-ladder TTFT storm; keep
				// both (the attempt-0 path emits neither, unchanged).
				retryAfter := s.estimateTTFTRetryAfter(d.model, bestTTFT, d.deadline)
				s.recordRejection(d.rejectionInfoWithDecision("dispatch", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, decision))
				d.recordDispatchedRequestOutcome(
					d.kvBackendAttribution(), classifyOutcomeByCode(http.StatusTooManyRequests))
			}
			s.writeTTFTTooSlow(w, d.model, d.publicModel, bestTTFT, d.deadline)
			return outcomeResponseWritten
		}

		// dispatchOneProvider may have found a provider but rejected it
		// (payout destination missing, insufficient funds, encryption
		// missing). In that case it already added the provider to
		// excludeProviders. If there may be more providers to try,
		// continue to the next attempt.
		providerWasRejected := dispatchErr != "no provider available"
		if providerWasRejected {
			d.setLastError(dispatchErr, dispatchErrCode)
			return outcomeRetry
		}

		// On retry attempts, don't queue — if the only available
		// providers already failed, waiting 120s for one of them
		// to come back won't help. Break and return the last error.
		// Don't overwrite lastErr/lastErrCode from the real provider
		// error — preserve the original status code.
		if d.providerBodyTooLargeErr != "" &&
			d.lastErrCode == http.StatusRequestEntityTooLarge &&
			decision.CapacityRejections == 0 {
			d.latchProviderBodyTooLarge(d.providerBodyTooLargeErr)
			return outcomeFailFast
		}
		if attempt > 0 && !d.shouldQueueCompatibleProvider(decision) {
			if d.lastErr == "" {
				d.setLastError(dispatchErr, dispatchErrCode)
			}
			return outcomeFailFast
		}
		// No idle provider — try queueing.
		d.requestID = uuid.New().String()
		queuePR := &registry.PendingRequest{
			RequestID:              d.requestID,
			Attempt:                d.attempt,
			Model:                  d.model,
			PublicModel:            d.publicModel,
			ConsumerKey:            d.consumerKey,
			KeyID:                  keyIDFromContext(r.Context()),
			KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
			KeyLimitReset:          keyLimitResetFromContext(r.Context()),
			ConsumerLocation:       d.consumerLocation,
			IsResponsesAPI:         d.isResponsesAPI,
			EstimatedPromptTokens:  d.estimatedPromptTokens,
			RequiresVision:         d.requiresVision,
			Traits:                 d.traits(),
			RequestedMaxTokens:     d.requestedMaxTokens,
			TokenAdmission:         d.tokenAdmission,
			ReservedMicroUSD:       d.reservedMicroUSD,
			BaseReservedMicroUSD:   d.reservedMicroUSD,
			ServiceReservation:     d.serviceReservation,
			AllowedProviderSerials: d.allowedProviderSerials,
			ExcludedProviderIDs:    d.excludedProviderIDs(),
			CachePlan:              d.cachePlan,
			SelfRouteOnly:          d.policy.enabled,
			PreferOwner:            d.policy.prefer,
			OwnerAccountID:         d.policy.ownerAccountID,
			FreeSelfRoute:          d.policy.enabled,
			MetadataDetails:        d.metadataDetails,
			MaxTTFTMs: queueMaxTTFTMs(
				d.policy, d.deadline, d.s.hardTTFTGateApplies(d.requiresVision)),
			MinDecodeTPS: d.s.minDecodeTPS,
			AcceptedCh:   make(chan struct{}, 1),
			ChunkCh:      make(chan registry.ProviderChunk, chunkBufferSize),
			CompleteCh:   make(chan protocol.UsageInfo, 1),
			ErrorCh:      make(chan protocol.InferenceErrorMessage, 1),
			Timing:       d.timing,
		}
		d.configurePending(queuePR)
		if receivedAt := timingReceivedAt(d.timing); !receivedAt.IsZero() {
			queuePR.FirstContentDeadline = receivedAt.Add(d.deadline)
		}
		if !queuePR.RefreshFirstContentBudget(time.Now()) {
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			return outcomeFailFast
		}
		queuedReq := &registry.QueuedRequest{
			RequestID:  d.requestID,
			Model:      d.model,
			Pending:    queuePR,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		queuePR.Timing.QueuedAt = time.Now()
		queuePR.Profile = d.profile.NewAttempt(d.requestID, d.attempt, "")
		queuePR.Profile.Mark(registry.StampAttemptStart)
		queuePR.Profile.Mark(registry.StampQueued)
		// Every exit of the queue path that never reached the wire (queue full,
		// wait cancelled/expired, TTFT/tool refusals, and a pre-wire failure
		// after the queue handed over a provider: top-up, key, encrypt, writer
		// timeout, write error) closes the placeholder attempt here so it never
		// waits on a provider terminal that cannot come. Keyed on the attempt's
		// own write-done stamp inside closeUndispatchedAttempt, never on d.pr:
		// d.pr is assigned before the write, so a failure between assignment
		// and the wire is still undispatched.
		defer d.closeQueuedAttempt(queuePR.Profile)
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			s.ddIncr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model), "outcome:over_capacity"})
			// No route row exists for a request the queue refused (the routing
			// decision is recorded only after a successful enqueue); the
			// placeholder carries the rejection vocabulary directly.
			queuePR.Profile.SetOutcome("rejected", "queue_full", "", "", "")
			retryAfter := s.estimateRetryAfter(d.model)
			d.refundReservation()
			info := d.rejectionInfoWithDecision("queue", "queue_full", http.StatusTooManyRequests, retryAfter*1000, decision)
			if d.policy.enabled {
				d.preContentTerminal(info, retryAfter, "machine_busy",
					"your machine is at capacity — retry shortly", "machine_busy")
			} else {
				d.preContentTerminal(info, retryAfter, "rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", d.publicModel),
					"rate_limit_exceeded")
			}
			return outcomeResponseWritten
		}
		s.recordWarmPoolQueueState(d.model)
		// Routing v2 W3: the model now has queued demand — proactively warm a cold
		// provider for it (TriggerModelSwaps) instead of waiting for the next
		// heartbeat, so the queued request drains onto it sooner.
		s.kickColdDispatch(d.model)
		s.ddIncr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model), "outcome:queued"})
		d.recordRoutingDecision(decision, "", "queued")

		s.logger.Info("request queued, waiting for provider",
			"model", d.model,
			"attempt", attempt+1,
		)

		var err error
		queueCtx, cancelQueue := firstTokenWriteContext(
			r.Context(), timingReceivedAt(d.timing), d.deadline)
		d.provider, err = s.registry.Queue().WaitForProviderContext(queueCtx, queuedReq)
		cancelQueue()
		if err != nil {
			if errors.Is(err, context.Canceled) {
				s.recordWarmPoolQueueState(d.model)
				d.emitClientGone(phaseBeforeFirstToken)
				d.queuedExitOutcome(queuePR.Profile, "cancelled", "client_gone", 0)
				d.refundReservation()
				return outcomeClientGone
			}
			if errors.Is(err, context.DeadlineExceeded) ||
				errors.Is(err, registry.ErrQueueFirstContentDeadline) {
				s.recordWarmPoolQueueState(d.model)
				d.queuedExitOutcome(queuePR.Profile,
					"timeout", "first_chunk_timeout", http.StatusGatewayTimeout)
				d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
				return outcomeFailFast
			}
			if errors.Is(err, registry.ErrQueueTTFTTooSlow) {
				// The drain proved every eligible provider fails ONLY the TTFT
				// ceiling — deterministic, so answer with the standard
				// ttft_too_slow 429 instead of waiting out the queue.
				s.recordWarmPoolQueueState(d.model)
				d.queuedExitOutcome(queuePR.Profile, "error", "ttft_too_slow", http.StatusTooManyRequests)
				d.refundReservation()
				s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
				s.triggerWarmPool()
				bestTTFT := time.Duration(queuedReq.Decision.BestTTFTMs * float64(time.Millisecond))
				retryAfter := s.estimateTTFTRetryAfter(d.model, bestTTFT, d.deadline)
				d.ttftTooSlowTerminal(
					d.rejectionInfoWithDecision("queue", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, queuedReq.Decision),
					retryAfter,
					ttftTooSlowMessage(d.publicModel, bestTTFT, d.deadline, retryAfter))
				return outcomeResponseWritten
			}
			if errors.Is(err, registry.ErrQueueToolConstraintUnavailable) {
				s.recordWarmPoolQueueState(d.model)
				d.queuedExitOutcome(queuePR.Profile,
					"error", "model_capability_unsupported",
					http.StatusServiceUnavailable)
				d.refundReservation()
				d.preContentTerminal(
					d.rejectionInfoWithDecision(
						"queue", "model_capability_unsupported",
						http.StatusServiceUnavailable, 0, queuedReq.Decision),
					0,
					"model_unavailable",
					fmt.Sprintf(
						"no online provider for model %q supports inference-time tool_choice enforcement",
						d.publicModel),
					"model_unavailable")
				return outcomeResponseWritten
			}
			d.queuedExitOutcome(queuePR.Profile, "timeout", "queue_timeout", http.StatusTooManyRequests)
			d.refundReservation()
			s.ddIncr("request_queue.timeout", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model)})
			s.registry.RecordWarmPoolQueueTimeout(d.model, time.Since(queuedReq.EnqueuedAt))
			retryAfter := s.estimateRetryAfter(d.model)
			info := d.rejectionInfoWithDecision("queue", "queue_timeout", http.StatusTooManyRequests, retryAfter*1000, decision)
			if d.policy.enabled {
				d.preContentTerminal(info, retryAfter, "machine_busy",
					"your machine is at capacity (timed out waiting for a free slot) — retry shortly",
					"machine_busy")
			} else {
				d.preContentTerminal(info, retryAfter, "rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", d.publicModel),
					"rate_limit_exceeded")
			}
			return outcomeResponseWritten
		}
		s.recordWarmPoolQueueState(d.model)
		// Queue assigned a provider; still need to dispatch.
		// Use the queue PR's channels.
		d.pr = queuePR
		d.requestID = d.pr.RequestID
		d.timing.RoutedAt = time.Now()
		if ap := d.pr.Profile; ap != nil {
			ap.Mark(registry.StampDequeued)
			ap.Mark(registry.StampReserveDone)
			ap.SetDecision(queuedReq.Decision)
			ap.ProviderID = d.provider.ID
			d.provider.Mu().Lock()
			ap.ProviderVersion = d.provider.Version
			ap.ChipFamily = d.provider.Hardware.ChipFamily
			d.provider.Mu().Unlock()
			ap.KVBackend, _ = d.provider.SlotKVBackendTags(d.model)
		}
		d.recordRoutingDecisionFor(d.provider, d.pr, d.requestID, d.pr.Attempt, queuedReq.Decision, "", "selected")

		// Log missing payout destination but don't skip — earnings
		// are credited to the provider's internal ledger and can be
		// withdrawn once they complete Stripe Connect onboarding.
		// A queued request settles FREE when its drained provider is the
		// caller's own machine: exclusive self-route always, OR a prefer
		// request whose selected provider is owned (settlement refunds to
		// zero). Skip the payout warning and the custom-price top-up then
		// (the top-up could otherwise 429 the free owned route).
		queuedSettlesFree := d.policy.enabled
		if !queuedSettlesFree && d.policy.prefer {
			d.provider.Mu().Lock()
			queuedSettlesFree = d.policy.ownerAccountID != "" && d.provider.AccountID == d.policy.ownerAccountID
			d.provider.Mu().Unlock()
		}

		if s.billing != nil && !queuedSettlesFree && !providerHasPayoutDestination(d.provider) {
			s.logger.Warn("queued provider missing payout destination, crediting to internal ledger",
				"request_id", d.requestID,
				"provider_id", d.provider.ID,
			)
		}

		// Custom pricing check — provider may charge more than the
		// platform rate. Reserve the additional amount now. Skipped for
		// free self-route, which settles at zero cost.
		if s.billing != nil && !queuedSettlesFree {
			if _, err := s.reserveAdditionalForProvider(d.pr, d.provider); err != nil {
				d.provider.RemovePending(d.requestID)
				s.registry.SetProviderIdle(d.provider.ID)
				d.excludeProviders[d.provider.ID] = struct{}{}
				if errors.Is(err, store.ErrInsufficientBalance) {
					s.logger.Warn("queued provider pricing exceeds balance, skipping",
						"request_id", d.requestID,
						"provider_id", d.provider.ID,
						"error", err,
					)
					d.setLastError("insufficient funds for provider price", http.StatusPaymentRequired)
					d.updateRoutingOutcome(d.errorRoutingOutcome("error", "insufficient_funds", d.lastErrCode))
				} else {
					s.logger.Error("queued provider reservation failed (DB error)",
						"request_id", d.requestID,
						"provider_id", d.provider.ID,
						"error", err,
					)
					d.setLastError("service temporarily unavailable — please retry", http.StatusServiceUnavailable)
					d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", d.lastErrCode))
				}
				return outcomeRetry
			}
		}
		// Perform E2E encryption and send the request.
		if d.provider.PublicKey == "" {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.setLastError("no provider with E2E encryption", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "encryption_missing", 0))
			return outcomeRetry
		}
		providerPubKey, err := e2e.ParsePublicKey(d.provider.PublicKey)
		if err != nil {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.setLastError("provider public key invalid", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
		sessionKeys, err := e2e.GenerateSessionKeys()
		if err != nil {
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.setLastError("failed to generate session keys", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
		if err := s.registry.PrepareCacheAttempt(d.pr, d.provider); err != nil {
			s.registry.ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.setLastError("failed to prepare cache-safe request", http.StatusInternalServerError)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", http.StatusInternalServerError))
			return outcomeRetry
		}
		// Version-gated penalty strip plus protocol-0 cache isolation. The queued
		// path seals here, separately from dispatchOneProvider.
		sealedBody, err := bodyForCacheAttempt(d.rawBody, d.requiresVision, d.provider, d.pr)
		if err != nil {
			s.registry.ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			if errors.Is(err, errProviderBodyTooLarge) {
				d.excludeProviders[d.provider.ID] = struct{}{}
				d.noteProviderBodyTooLarge(err.Error(), oversizedProviderBodyBytes(err))
				d.updateRoutingOutcome(d.errorRoutingOutcome(
					"error", errorClassClientError, http.StatusRequestEntityTooLarge))
				return outcomeRetry
			}
			d.setLastError("failed to prepare provider request", http.StatusInternalServerError)
			d.updateRoutingOutcome(d.errorRoutingOutcome(
				"error", "provider_error", http.StatusInternalServerError))
			return outcomeRetry
		}
		encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
		if err != nil {
			s.registry.ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.setLastError("failed to encrypt request", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "encryption_missing", 0))
			return outcomeRetry
		}
		d.timing.EncryptedAt = time.Now()
		d.pr.Profile.Mark(registry.StampEncrypted)
		d.pr.SessionPrivKey = &sessionKeys.PrivateKey
		// pr.ReservedMicroUSD was already set in the struct literal and may
		// have been increased by reserveAdditionalForProvider. Don't overwrite.
		// Bound the provider write by the request-absolute first-token clock:
		// WriteText blocks until the frame is on the wire (write watchdog
		// allows 5-30s per frame), so an unbounded write could eat the budget
		// while the aggregator's cancel clock keeps running.
		writeCtx, cancelWrite := firstTokenWriteContext(r.Context(), timingReceivedAt(d.timing), d.deadline)
		d.pr.Profile.Mark(registry.StampWriteSubmitted)
		_, writeErr := writeProviderInferenceRequestDeferred(
			writeCtx,
			d.provider,
			providerInferenceFrameBuilder(
				d.requestID, encrypted.EphemeralPublicKey, encrypted.Ciphertext, d.pr),
			func(metadata registry.TextFrameWriteMetadata) {
				d.timing.DispatchedAt = metadata.DequeuedAt
				d.noteProviderDispatched()
				d.pr.Profile.MarkAt(registry.StampWriteDequeued, metadata.DequeuedAt)
			},
		)
		cancelWrite()
		if writeErr == nil {
			d.pr.Profile.Mark(registry.StampWriteDone)
		}
		if writeErr != nil {
			s.registry.ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			if errors.Is(writeErr, context.DeadlineExceeded) ||
				errors.Is(writeErr, errFirstContentDeadlineAtWriter) {
				d.pr.Profile.Mark(registry.StampCancelSent)
				s.sendProviderCancel(d.provider, d.requestID)
				d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
				d.updateRoutingOutcome(d.errorRoutingOutcome(
					"timeout", "first_chunk_timeout", http.StatusGatewayTimeout))
				return outcomeFailFast
			}
			d.setLastError("failed to send request to provider", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
	}
	// The request is now on a slot. Latch that slot's KV backend so the
	// exhaustion ladder can still attribute the outcome after a failover has
	// cleared d.provider/d.pr (v0.8.0 paged rollout, Gate G5).
	d.noteServingSlot()
	// Routing v2 W2: the primary frame is handed off — confirm the retained
	// alternates in parallel with the in-flight prompt (one probe round per
	// request; zero added primary latency by construction).
	d.maybeProbePlanCandidates()
	return outcomeProceed
}

// noteDispatchRetry feeds the inference-error breaker + refund for a pre-commit
// provider error and, unless held boilerplate was discarded (which emits its own
// pre-content failover counter), emits the generic retry counter. This is the
// exact `if !d.noteProviderError(...) { s.ddIncr(retry) }` pattern.
func (d *dispatchState) noteDispatchRetry(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string) {
	if !d.noteProviderError(provider, pr, statusCode, errStr, errReason, terminalCause, held) {
		d.s.ddIncr("inference.dispatches", []string{"status:retry"})
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
func (d *dispatchState) noteProviderError(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string) (discardedHeld bool) {
	if isProviderHealthNeutralErrorReason(errReason) {
		provider = nil
	}
	return d.s.noteDispatchProviderError(provider, pr, statusCode, errStr, errReason, terminalCause, held)
}

// rejectionReasonOversized is the rejection-ledger reason_code for a request the
// dispatch loop stopped because no provider can serve it (deterministic context
// overflow, or a transient-capacity shortage that exhausted
// maxCapacityClassRetries). Distinct from the preflight "context_exceeded" /
// "prompt_too_long" and the legacy dispatch-exhausted "unservable_token_budget".
const rejectionReasonOversized = "oversized_request"

// rejectionReasonRoutingSaturated is the rejection-ledger reason_code for a
// request shed because no provider-selection scan slot freed up within its
// remaining first-content budget (Server.routingScanSem — the coordinator
// itself was the bottleneck, 2026-09-01 collapse). Capacity-shaped: one
// retryable 429, uptime-neutral, zero providers contacted.
const rejectionReasonRoutingSaturated = "routing_saturated"

// rejectionReasonDeadlineUnreachable is the rejection-ledger reason for a
// request whose remaining absolute first-content budget was refused by one or
// more providers and whose untried candidates were then exhausted.
const rejectionReasonDeadlineUnreachable = errorReasonDeadlineUnreachable

// rejectionReasonTemplateRenderFailed is the rejection-ledger reason_code for
// a request the dispatch loop stopped because the model's chat template
// cannot render it (provider error_reason jinja_channel_tags /
// jinja_null_bridge / jinja_template — see envJinjaTerminalReject).
// Distinguishable from the StatusCode-driven stop's generic "client_error".
const rejectionReasonTemplateRenderFailed = "template_render_failed"

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
func (d *dispatchState) shouldStopFailover() bool {
	// Honor a previously-latched verdict (incl. a client-shape 4xx latched from a
	// speculative race loser, whose code never lands in d.lastErrCode).
	if d.unservable || d.terminalClientError {
		return true
	}
	// StatusCode-driven stop BEFORE the string classifier: a deterministic provider
	// client 4xx is identical on every provider, so retrying is pure waste (the 29×
	// storm). String-blind on purpose — the code is ground truth here.
	if !d.s.disableClientErrorStop && isTerminalClientErrorCode(d.lastErrCode) {
		d.s.ddIncr("routing.dispatch_client_error_stop", []string{"model:" + d.model, "code:" + strconv.Itoa(d.lastErrCode)})
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
	if d.lastErrCode == http.StatusGatewayTimeout && !isTypedTimeout504Cause(d.lastErrTerminalCause) {
		d.firstChunkTimeoutRetries++
		if d.firstChunkTimeoutRetries >= maxFirstChunkTimeoutRetries {
			d.s.ddIncr("routing.first_chunk_timeout_ladder_capped", []string{"model:" + d.model})
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
	kind := classifyRejection(d.lastErrReason, d.lastErr, d.lastErrProviderBudget, d.modelMaxContext, d.lastErrRejectionReason)
	if kind != rejectionDeadlineUnreachable &&
		d.lastErrTerminalCause == terminalCauseAdmissionTimeout {
		kind = rejectionTransientCapacity
	}
	switch kind {
	case rejectionDeterministicUnservable:
		d.s.ddIncr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:deterministic"})
		d.unservable = true
		d.unservableReason = rejectionReasonOversized
		return true
	case rejectionDeadlineUnreachable:
		// This provider declined only the remaining request-absolute SLA.
		// Another untried provider may still land, so keep failing over without
		// consuming the generic transient-capacity retry allowance.
		d.lastFailureDeadline = true
		return false
	case rejectionTransientCapacity:
		d.s.ddIncr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:transient"})
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
func (d *dispatchState) latchJinjaTerminalReject(reason, src string) (latched bool) {
	if !jinjaTerminalRejectEnabled() || !isJinjaTemplateErrorReason(reason) {
		return false
	}
	tags := []string{"model:" + d.model, "code:422", "reason:" + normalizeInferenceErrorReason(reason)}
	if src != "" {
		tags = append(tags, "src:"+src)
	}
	d.s.ddIncr("routing.dispatch_client_error_stop", tags)
	d.terminalClientError = true
	d.terminalClientErrorCode = http.StatusUnprocessableEntity
	d.terminalClientErrorReason = rejectionReasonTemplateRenderFailed
	d.terminalClientErrorMessage = jinjaTerminalRejectMessage
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
func (d *dispatchState) latchDeterministicLoser(provider *registry.Provider, msg protocol.InferenceErrorMessage) {
	msg = normalizeInferenceErrorForInternalUse(msg)
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
	if !d.s.disableClientErrorStop && isTerminalClientErrorCode(msg.StatusCode) {
		d.s.ddIncr("routing.dispatch_client_error_stop", []string{"model:" + d.model, "code:" + strconv.Itoa(msg.StatusCode), "src:race_loser"})
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
	switch classifyRejection(msg.ErrorReason, msg.Error, budget, d.modelMaxContext, msg.RejectionReason) {
	case rejectionDeadlineUnreachable:
		// A race loser that could not meet the remaining absolute deadline is
		// health-neutral and non-deterministic across providers. It must not
		// become sticky: the surviving attempt owns the eventual terminal.
	case rejectionDeterministicUnservable:
		d.s.ddIncr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:deterministic"})
		d.unservable = true
		d.unservableReason = rejectionReasonOversized
		d.latchTerminalAttribution(provider)
	}
}

// waitFirstChunk runs the speculative TTFT-aware first-chunk wait (the former
// `firstChunkWait` labeled loop). It holds preamble chunks, commits on first
// content, ignores AcceptedCh for race/timer decisions, may proceed to
// waitAccepted only for legacy preamble liveness, retries invisibly on provider
// error/timeout, and launches the speculative backup race when the primary is
// slow. Returns outcomeCommitted (content / clean close), outcomeAccepted
// (legacy preamble liveness — proceed to waitAccepted), outcomeRetry
// (advance to the next attempt), or outcomeClientGone (context cancelled, refunded).
func (d *dispatchState) waitFirstChunk() (outcome dispatchOutcome) {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr
	captured := routingAttempt(provider, pr, pr.RequestID, pr.Attempt)

	defer func() {
		target := d.currentOrCapturedRoutingAttempt(captured)
		switch outcome {
		case outcomeCommitted:
			d.updateRoutingOutcomeForAttempt(target, d.successRoutingOutcomeFor(target.pending))
		case outcomeRetry:
			// A 504 here is a coordinator-synthesized first-chunk timeout
			// unless it carries a KNOWN typed 504 cause (safety_deadline /
			// backpressure_timeout) — those are real provider terminals and
			// keep their provider-error route class and attempt usage.
			// setLastError clears the cause for synthetic timeouts (so the
			// discriminator cannot go stale), and an UNKNOWN cause value
			// stays on this legacy timeout path, mirroring
			// classifyTerminalCause's unknown→legacy rule for mixed-version
			// rollouts.
			if d.lastErrCode == http.StatusGatewayTimeout && !isTypedTimeout504Cause(d.lastErrTerminalCause) {
				d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "timeout", "first_chunk_timeout", d.lastErrCode))
			} else {
				// Post-dispatch provider failure (incl. OOM/model-load): admitted but failed.
				d.updateRoutingOutcomeForAttempt(target, d.providerFailedRoutingOutcomeFor(target.pending))
			}
		case outcomeClientGone:
			d.emitClientGone(phaseBeforeFirstToken)
			d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "cancelled", "client_gone", 0))
		}
	}()

	deadlineWait := d.firstTokenWait(d.deadline)
	speculativeTimer := time.NewTimer(d.firstTokenSpeculativeWait())
	deadlineTimer := time.NewTimer(deadlineWait)
	// Routing v2 W2: the probe round may deliver ONE refined (strictly
	// earlier) absolute speculative launch instant. Read through a local so
	// the arm disarms itself after its single use; a nil channel (no probe
	// round) never fires.
	hedgeAdvance := d.hedgeAdvanceCh
	// preambleLiveness records that held boilerplate earned a legacy bounded
	// extension. AcceptedCh never earns or resets a content wait.
	// A preamble-then-stall with leftover budget is still bounded by
	// preambleContentTimeout so a role-then-stall zombie fails over.
	d.preambleLiveness = false

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				if d.firstTokenSpeculativeWait() <= 0 {
					speculativeTimer.Stop()
					deadlineTimer.Stop()
					return d.runSpeculative()
				}
				continue
			}
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					// Closed without error — commit (held chunks only is
					// fine: a preamble-then-complete stream is empty output).
					d.committed = true
				}
			}
			return outcomeCommitted

		case <-pr.AcceptedCh:
			// Acceptance is not content and must not suppress either the
			// speculative launch point or the absolute first-content timer.
			continue

		case errMsg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"failure_code", errMsg.FailureCode,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case at := <-hedgeAdvance:
			// One-shot re-arm of the speculative timer to the probe round's
			// refined launch instant. Guards, in order: only once (the local
			// disarms), only with the absolute clock stamped (mirrors
			// first_token_clock.go invariant 5), only strictly EARLIER than
			// the armed point, and never after the timer fired — Stop()
			// reports whether the timer was still pending; a spent fire stays
			// buffered in C for its own arm and must not be re-armed over.
			// Never past the deadline by construction: hedgeLaunchAt's
			// ceiling is deadline/2. speculativeAt is updated so every
			// downstream remaining-window computation, the launch-now check
			// above, and telemetry agree with the re-armed timer; without a
			// delivered value it stays the 50% default — exact legacy timing.
			hedgeAdvance = nil
			receivedAt := timingReceivedAt(d.timing)
			if receivedAt.IsZero() || !at.Before(receivedAt.Add(d.speculativeAt)) {
				continue
			}
			if !speculativeTimer.Stop() {
				continue
			}
			d.speculativeAt = at.Sub(receivedAt)
			if d.speculativeAt < 0 {
				d.speculativeAt = 0
			}
			speculativeTimer.Reset(d.firstTokenSpeculativeWait())
			continue

		case <-speculativeTimer.C:
			if pr.FirstContentIngressArrivedByDeadline() {
				if d.onSpeculativeDeferral != nil {
					d.onSpeculativeDeferral()
				}
				continue
			}
			deadlineTimer.Stop()
			return d.runSpeculative()

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Preamble liveness — the provider is alive but still in its
				// pre-content phase. Fall through to waitAccepted, still
				// bounded by leftover request-absolute first-token budget.
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.cancelDispatchForFirstContentTimeout(provider, pr) {
				continue
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			s.logger.Warn("provider timeout (full deadline), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// runSpeculative is the speculativeTimer.C arm of waitFirstChunk: the primary is
// slow, so dispatch a speculative backup (unless this is a prefer request being
// served by the caller's own machine) and either keep waiting for the primary
// alone (no backup available) or race primary vs backup. Returns the same outcome
// set as waitFirstChunk.
func (d *dispatchState) runSpeculative() dispatchOutcome {
	s := d.s
	r := d.r
	provider := d.provider
	if d.onSpeculativeDispatch != nil {
		d.onSpeculativeDispatch()
	}
	if _, empty := d.pr.OnTimeEmptyCompletionIngress(); empty {
		return d.waitAccepted()
	}

	// Primary is slow. Attempt speculative backup dispatch.
	s.ddIncr("inference.speculative_dispatch", []string{"model:" + d.model})
	s.registry.RecordWarmPoolSpeculativeStarted(d.model)

	var backupProvider *registry.Provider
	var attemptedBackupProvider *registry.Provider
	var backupPR *registry.PendingRequest
	var backupErr string
	var backupErrCode int
	backupRouteRecorded := false
	backupRouteRequestID := ""
	backupRouteAttempt := d.attempt

	// Do NOT speculatively race a paid PUBLIC backup against a prefer
	// request that is being served by the caller's OWN machine: the user
	// opted into "prefer my machine (free)", so a slow owned machine must
	// be waited on, not raced (and billed) by the public fleet. (Exclusive
	// self-route is already safe — its backup selection is owned-only and
	// returns nil when there's no other owned machine.) When the prefer
	// primary is itself a public provider (the owner owns nothing / fell
	// back), normal speculative behaviour applies.
	skipBackup := false
	if d.policy.prefer {
		provider.Mu().Lock()
		skipBackup = d.policy.ownerAccountID != "" && provider.AccountID == d.policy.ownerAccountID
		provider.Mu().Unlock()
	}

	// Hedge governor (Routing v2 Phase 4): insurance must never amplify an
	// overload. A non-allow verdict suppresses the backup entirely and falls
	// through the nil-backup branch below — byte-identical to today's
	// "no backup available" path. The owner-served prefer skip above stays
	// governor-blind: it is a product rule, not a capacity decision.
	//
	// The verdict and the budget-slot increment are ONE atomic governor
	// operation (tryAcquireHedge): concurrent slow requests can no longer
	// each read the last free slot and all launch past the fleet-wide cap.
	// An acquired slot is released exactly once — below when no backup
	// actually dispatches, at race resolution otherwise.
	hedgeLaunched := false
	if !skipBackup && s.hedgeGov != nil {
		verdict, acquired := d.tryAcquireBackupHedge(provider.ID)
		d.hedgeGovernorVerdict = verdict.String()
		hedgeLaunched = acquired
		if verdict != hedgeAllow {
			s.ddIncr("routing.hedge_governor_suppressed", []string{"model:" + d.model, "verdict:" + verdict.String()})
			s.logger.Info("speculative_backup_suppressed",
				"request_id", d.requestID,
				"primary_provider", provider.ID,
				"verdict", verdict.String(),
			)
			skipBackup = true
		}
	}

	if !skipBackup {
		d.pr.EnableSpeculativeEmptyCompletionArbitration()
		backupExclude := make(map[string]struct{}, len(d.excludeProviders)+1)
		for id := range d.excludeProviders {
			backupExclude[id] = struct{}{}
		}
		backupExclude[provider.ID] = struct{}{}

		recordBackupRoute := func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
			attemptedBackupProvider = provider
			if pr != nil {
				pr.EnableSpeculativeEmptyCompletionArbitration()
				d.configurePending(pr)
				backupRouteRecorded = true
				backupRouteRequestID = pr.RequestID
				backupRouteAttempt = pr.Attempt
			}
			d.recordRoutingDecisionFor(provider, pr, "", d.attempt, decision, "", "")
		}
		// Routing v2 W2: the backup consumes the retained plan first — the
		// next confirmed/revalidated entry, then the request's single refresh
		// — falling back to the legacy full scan only when the plan machinery
		// yields nothing (prefer-owner and legacy fleets keep their exact
		// selection behavior). The backup shares only ReceivedAt with the
		// primary's clock, as before.
		backupTiming := &registry.RequestTiming{ReceivedAt: d.timing.ReceivedAt}
		planTried := false
		backupProvider, backupPR, _, backupErr, backupErrCode, planTried =
			d.dispatchFromPlanMachinery(backupTiming, backupExclude, d.requestID, recordBackupRoute)
		if !planTried {
			backupProvider, backupPR, _, _, backupErr, backupErrCode = s.dispatchOneProvider(
				r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
				d.estimatedPromptTokens, d.deadline, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
				d.traits(),
				d.allowedProviderSerials, d.isResponsesAPI, d.policy,
				backupTiming,
				d.serviceReservation,
				d.cachePlan,
				backupExclude,
				d.attempt, d.profile, d.requestID,
				recordBackupRoute,
				d.noteProviderDispatched,
			)
		}
	}

	if backupProvider == nil {
		if hedgeLaunched {
			// The governor admitted a hedge that never dispatched — release
			// its budget slot immediately. No outcome is recorded: no race
			// ran, so there is nothing to fold into the win-rate EWMA.
			s.hedgeGov.noteHedgeResolved()
		}
		if d.pr != nil {
			d.pr.ResolveSpeculativeEmptyCompletion(true)
		}
		if backupErrCode == http.StatusRequestEntityTooLarge && attemptedBackupProvider != nil {
			d.noteProviderBodyTooLargeFor(attemptedBackupProvider, backupErr)
		}
		if backupRouteRecorded {
			d.s.updateInferenceRouteOutcomeWithModel(backupRouteRequestID, backupRouteAttempt, d.model, d.errorRoutingOutcome("error", dispatchErrorClass(backupErr), backupErrCode))
		}
		// No backup available. Keep waiting for primary with remaining deadline.
		s.logger.Info("speculative_dispatch_no_backup",
			"request_id", d.requestID,
			"primary_provider", provider.ID,
		)
		return d.waitNoBackup()
	}
	// Backup dispatched — race primary vs backup.
	if d.pr != nil {
		d.pr.UsedBackup = true
		if ap := d.pr.Profile; ap != nil {
			ap.BackupLaunched.Store(true)
		}
	}
	if backupPR != nil {
		backupPR.UsedBackup = true
	}
	s.logger.Info("speculative_dispatch",
		"request_id", d.requestID,
		"primary_provider", provider.ID,
		"backup_provider", backupProvider.ID,
		"ttft_deadline_ms", d.deadline.Milliseconds(),
		"speculative_at_ms", d.speculativeAt.Milliseconds(),
	)
	outcome := d.runRace(backupProvider, backupPR)
	if hedgeLaunched {
		// Exactly-once hedge accounting: every runRace exit — win, loss,
		// retry, client-gone, empty-completion promotion, and the failed-racer
		// sub-waits — returns through here, and BackupWon is the winner marker
		// every backup-win path sets before committing.
		s.hedgeGov.noteHedgeResolved()
		s.hedgeGov.recordHedgeOutcome(d.model, backupPR.BackupWon)
	}
	return outcome
}

// waitNoBackup is the speculative-no-backup branch (`noBackupWait`): keep waiting
// for the primary alone with the remaining deadline. d.provider / d.pr are the primary.
func (d *dispatchState) waitNoBackup() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	remainingDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			remainingDeadline.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			continue
		case errMsg := <-pr.ErrorCh:
			remainingDeadline.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-remainingDeadline.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Liveness: the provider already produced its preamble.
				// Fall through to waitAccepted, still bounded by leftover
				// request-absolute first-token budget.
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.cancelDispatchForFirstContentTimeout(provider, pr) {
				continue
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			s.logger.Warn("provider timeout (no backup), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			remainingDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

func emptyCompletionPrecedesChunk(
	empty *registry.PendingRequest,
	chunk registry.ProviderChunk,
) bool {
	completedAt, ok := empty.OnTimeEmptyCompletionIngress()
	return ok &&
		!chunk.ReceivedAt.IsZero() &&
		!completedAt.After(chunk.ReceivedAt)
}

func (d *dispatchState) awaitPrimaryEmptyCompletion(
	backupProvider *registry.Provider,
	backupPR *registry.PendingRequest,
) dispatchOutcome {
	d.pr.ResolveSpeculativeEmptyCompletion(true)
	d.s.cancelDispatch(backupProvider, backupPR)
	d.markSpeculativeLoser(backupPR)
	return d.waitAccepted()
}

func (d *dispatchState) awaitBackupEmptyCompletion(
	primaryProvider *registry.Provider,
	primaryPR *registry.PendingRequest,
	backupProvider *registry.Provider,
	backupPR *registry.PendingRequest,
	backupHeld []string,
) dispatchOutcome {
	backupPR.ResolveSpeculativeEmptyCompletion(true)
	d.s.cancelDispatch(primaryProvider, primaryPR)
	d.s.ddIncr("inference.speculative_win", []string{"model:" + d.model})
	d.s.registry.RecordWarmPoolSpeculativeWon(d.model)
	d.markSpeculativeLoser(primaryPR)
	backupPR.BackupWon = true
	if ap := backupPR.Profile; ap != nil {
		ap.BackupWon.Store(true)
		if primaryPR != nil {
			ap.CopyPreDispatchFrom(primaryPR.Profile)
		}
	}
	d.provider = backupProvider
	d.pr = backupPR
	d.requestID = backupPR.RequestID
	d.heldChunks = backupHeld
	d.noteServingSlot()
	return d.waitAccepted()
}

// runRace is the speculative `race` loop: primary (d.provider/d.pr) vs backup,
// first CONTENT chunk wins; the loser is cancelled. Preamble from each racer is
// buffered separately (held chunks must never mix providers). On a racer error the
// surviving racer is waited on via a sub-loop. Returns the waitFirstChunk outcome
// set; on a backup win d.provider/d.pr/d.requestID/d.heldChunks are swapped to the backup.
func (d *dispatchState) runRace(backupProvider *registry.Provider, backupPR *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	raceDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	// One-shot extension: when the race deadline expires but a racer
	// has shown liveness (preamble received), the race continues up to
	// leftover first-token budget (capped by preambleContentTimeout).
	raceExtended := false
	// Preamble chunks from the backup are buffered separately —
	// held chunks must never mix providers.
	var backupHeld []string
	primaryCompletion := pr.CompletionIngressSignal()
	backupCompletion := backupPR.CompletionIngressSignal()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				// Preamble only — the primary hasn't proven it can
				// generate; keep the backup racing for first content.
				if completedAt, empty := backupPR.OnTimeEmptyCompletionIngress(); empty &&
					!pr.ContentIngressAtOrBefore(completedAt) {
					raceDeadline.Stop()
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
				continue
			}
			if ok && emptyCompletionPrecedesChunk(backupPR, chunk) {
				raceDeadline.Stop()
				return d.awaitBackupEmptyCompletion(
					provider, pr, backupProvider, backupPR, backupHeld)
			}
			if !ok {
				primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress()
				backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress()
				if backupEmpty && (!primaryEmpty || backupAt.Before(primaryAt)) {
					raceDeadline.Stop()
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
			}
			// Primary wins!
			raceDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			if ok {
				d.markSpeculativeLoser(backupPR)
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					// Primary failed but we already cancelled backup.
					d.markSpeculativeLoser(backupPR)
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.markSpeculativeLoser(backupPR)
					d.committed = true
				}
			}
			return outcomeCommitted

		case chunk, ok := <-backupPR.ChunkCh:
			if ok && holdPreContentBoilerplate(backupPR, chunk, &backupHeld) {
				// Backup preamble doesn't win the race — first CONTENT does.
				if completedAt, empty := pr.OnTimeEmptyCompletionIngress(); empty &&
					!backupPR.ContentIngressAtOrBefore(completedAt) {
					raceDeadline.Stop()
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
				continue
			}
			if ok && emptyCompletionPrecedesChunk(pr, chunk) {
				raceDeadline.Stop()
				return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
			}
			if !ok {
				primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress()
				backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress()
				if primaryEmpty && (!backupEmpty || primaryAt.Before(backupAt)) {
					raceDeadline.Stop()
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
			}
			// Backup wins!
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			s.ddIncr("inference.speculative_win", []string{"model:" + d.model})
			s.registry.RecordWarmPoolSpeculativeWon(d.model)
			if ok {
				d.markSpeculativeLoser(pr)
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				// The backup is now the serving slot; re-latch so a
				// post-commit failure books under ITS backend, not the
				// cancelled primary's.
				d.noteServingSlot()
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-backupPR.ErrorCh:
					// Backup failed too. Keep primary context for retry.
					d.excludeProviders[backupProvider.ID] = struct{}{}
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					d.updateSpeculativeFailure(backupPR, errMsg)
					d.noteProviderError(backupProvider, backupPR, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &backupHeld)
					// Preserve a deterministic-unservable verdict from this loser so the
					// surviving primary's error can't mask it (see latchDeterministicLoser).
					d.latchDeterministicLoser(backupProvider, errMsg)
					// Wait remaining deadline for primary.
					return d.raceBackupChunkClosedWaitPrimary(provider, pr)
				default:
					// Backup channel closed with no error — treat as committed.
					s.cancelDispatch(provider, pr)
					d.markSpeculativeLoser(pr)
					backupPR.BackupWon = true
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.noteServingSlot()
					d.committed = true
				}
			}
			return outcomeCommitted

		case <-primaryCompletion:
			primaryCompletion = nil
			completedAt, empty := pr.OnTimeEmptyCompletionIngress()
			if !empty || backupPR.ContentIngressAtOrBefore(completedAt) {
				continue
			}
			if backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress(); backupEmpty && backupAt.Before(completedAt) {
				raceDeadline.Stop()
				return d.awaitBackupEmptyCompletion(
					provider, pr, backupProvider, backupPR, backupHeld)
			}
			raceDeadline.Stop()
			return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)

		case <-backupCompletion:
			backupCompletion = nil
			completedAt, empty := backupPR.OnTimeEmptyCompletionIngress()
			if !empty || pr.ContentIngressAtOrBefore(completedAt) {
				continue
			}
			if primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress(); primaryEmpty && primaryAt.Before(completedAt) {
				raceDeadline.Stop()
				return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
			}
			raceDeadline.Stop()
			return d.awaitBackupEmptyCompletion(
				provider, pr, backupProvider, backupPR, backupHeld)

		case <-pr.AcceptedCh:
			// Acceptance never wins a race. Both providers keep racing until
			// real content, error, or the absolute deadline.
			continue

		case <-backupPR.AcceptedCh:
			continue

		case errMsg := <-pr.ErrorCh:
			// Primary failed. Keep waiting for backup.
			raceDeadline.Stop()
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				if emptyCompletionPrecedesChunk(backupPR, chunk) {
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
				s.cancelDispatch(backupProvider, backupPR)
				d.markSpeculativeLoser(backupPR)
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				d.initialError = &errMsg
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastFailedVersion = failedProviderVersion(provider)
			d.updateSpeculativeFailure(pr, errMsg)
			d.noteProviderError(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
			// Preserve a deterministic-unservable verdict from this loser so the
			// surviving backup's error can't mask it (see latchDeterministicLoser).
			d.latchDeterministicLoser(provider, errMsg)
			d.requestID = ""
			d.provider = nil
			d.pr = nil
			backupPR.ResolveSpeculativeEmptyCompletion(true)
			return d.racePrimaryFailedWaitBackup(backupProvider, backupPR, backupHeld)

		case errMsg := <-backupPR.ErrorCh:
			// Backup failed. Keep waiting for primary.
			raceDeadline.Stop()
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				if emptyCompletionPrecedesChunk(pr, chunk) {
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
				s.cancelDispatch(provider, pr)
				d.markSpeculativeLoser(pr)
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = backupPR.RequestID
				d.heldChunks = backupHeld
				d.noteServingSlot()
				d.commitFirstContent(backupPR, chunk.Data)
				d.committed = true
				d.initialError = &errMsg
				return outcomeCommitted
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.cancelDispatch(backupProvider, backupPR)
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			d.updateSpeculativeFailure(backupPR, errMsg)
			d.noteProviderError(backupProvider, backupPR, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &backupHeld)
			// Preserve a deterministic-unservable verdict from this loser so the
			// surviving primary's error can't mask it (see latchDeterministicLoser).
			d.latchDeterministicLoser(backupProvider, errMsg)
			pr.ResolveSpeculativeEmptyCompletion(true)
			return d.raceBackupErrWaitPrimary(provider, pr)

		case <-raceDeadline.C:
			// A token that is already buffered beats the timer: the backup is
			// dispatched synchronously in runSpeculative, so an on-time primary
			// token can be sitting in ChunkCh when a zero-leftover timer fires.
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				if emptyCompletionPrecedesChunk(backupPR, chunk) {
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
				s.cancelDispatch(backupProvider, backupPR)
				d.markSpeculativeLoser(backupPR)
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				if emptyCompletionPrecedesChunk(pr, chunk) {
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
				s.cancelDispatch(provider, pr)
				s.ddIncr("inference.speculative_win", []string{"model:" + d.model})
				s.registry.RecordWarmPoolSpeculativeWon(d.model)
				d.markSpeculativeLoser(pr)
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.noteServingSlot()
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() ||
				backupPR.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if !raceExtended && (len(d.heldChunks) > 0 || len(backupHeld) > 0) {
				// Liveness from at least one racer: don't fail at the
				// relative TTFT slice — extend once by leftover
				// request-absolute first-token budget, capped by
				// preambleContentTimeout (zero bytes have reached the
				// client; a genuine cold load would have signalled
				// AcceptedCh).
				ext := d.firstTokenWait(preambleContentTimeout)
				if ext > preambleContentTimeout {
					ext = preambleContentTimeout
				}
				if ext > 0 {
					raceExtended = true
					raceDeadline = time.NewTimer(ext)
					continue
				}
			}
			if !s.cancelDispatchForFirstContentTimeout(provider, pr) {
				continue
			}
			if !s.cancelDispatchForFirstContentTimeout(backupProvider, backupPR) {
				// The primary was cancelled for the timeout but the backup
				// won its ingress race: record the primary's timeout (route
				// outcome + attempt profile) before its identity is cleared.
				d.updateSpeculativeTimeout(pr, "first_chunk_timeout")
				d.excludeProviders[provider.ID] = struct{}{}
				d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
				d.provider = nil
				d.pr = nil
				d.requestID = ""
				backupPR.ResolveSpeculativeEmptyCompletion(true)
				return d.racePrimaryFailedWaitBackup(
					backupProvider, backupPR, backupHeld)
			}
			// Both missed deadline. A racer that held preamble (role
			// then stall) is a 504-shaped sickness — feed the breaker
			// before cancelling, mirroring the single-provider
			// acceptedWait timeout path so a stalling provider/model
			// (shape-keyed) trips its cooldown.
			// Attribute each provider's complete initial+racing interval. The
			// prior extension-only check missed stalls split across phases.
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			if providerAttemptAttributableStall(
				backupPR, d.deadline-d.speculativeAt) {
				s.noteInferenceError(backupProvider.ID, backupPR, http.StatusGatewayTimeout, "", "", "")
			}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			d.updateSpeculativeTimeout(backupPR, "first_chunk_timeout")
			d.excludeProviders[provider.ID] = struct{}{}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			d.setLastError("timeout waiting for first response (both providers)", http.StatusGatewayTimeout)
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			raceDeadline.Stop()
			d.updateSpeculativeClientGone(backupPR)
			s.cancelDispatch(provider, pr)
			s.cancelDispatch(backupProvider, backupPR)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// raceBackupChunkClosedWaitPrimary handles the race sub-case where the backup's
// ChunkCh closed with an error (already recorded by the caller): wait the
// remaining deadline for the primary. This is the former `backupFailedPrimaryWait`
// loop. d.provider/d.pr remain the primary throughout (the backup already lost).
func (d *dispatchState) raceBackupChunkClosedWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	remainingPrimary := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			remainingPrimary.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.setLastInferenceError(provider, errMsg2)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.updateSpeculativeFailure(pr, errMsg2)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					d.requestID = ""
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			continue
		case errMsg2 := <-pr.ErrorCh:
			// Defensive: both ErrorCh senders currently send before
			// closing ChunkCh (the closed-ChunkCh check above catches
			// them), but a direct arm keeps this loop correct if that
			// ordering ever changes — mirroring its sibling wait loops.
			remainingPrimary.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg2) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.setLastInferenceError(provider, errMsg2)
			d.lastFailedVersion = failedProviderVersion(provider)
			d.updateSpeculativeFailure(pr, errMsg2)
			d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-remainingPrimary.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Primary preamble liveness — continue in waitAccepted
				// on leftover request-absolute first-token budget.
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.cancelDispatchForFirstContentTimeout(provider, pr) {
				continue
			}
			// The PRIMARY timed out here (the backup's earlier error
			// is already recorded); report the timeout, not the
			// backup's stale error text.
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.updateSpeculativeTimeout(pr, "first_chunk_timeout")
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-r.Context().Done():
			remainingPrimary.Stop()
			d.updateSpeculativeClientGone(pr)
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// racePrimaryFailedWaitBackup handles the race sub-case where the primary errored
// (already recorded): wait the remaining deadline for the backup, promoting it to
// the committed/accepted provider on success. This is the former
// `primaryFailedBackupWait` loop.
func (d *dispatchState) racePrimaryFailedWaitBackup(backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	s := d.s
	r := d.r
	// The primary already failed and d.pr is cleared: the BACKUP is the only
	// racer left, so every failure or timeout below is the backup's. Re-latch
	// now so the terminal outcome names the backup's backend rather than
	// falling back to the dead primary's latch. When the primary's failure
	// latched a DETERMINISTIC verdict (latchDeterministicLoser just ran), the
	// re-latch is a no-op by design: the terminal response will be the
	// primary's 4xx/422/429, so the primary keeps the attribution even
	// though the backup keeps racing (noteServingSlotFor's freeze rule).
	d.noteServingSlotFor(backupPR)
	backupDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-backupPR.ChunkCh:
			if ok && holdPreContentBoilerplate(backupPR, chunk, &backupHeld) {
				continue
			}
			backupDeadline.Stop()
			if ok {
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg2 := <-backupPR.ErrorCh:
					d.excludeProviders[backupProvider.ID] = struct{}{}
					s.cancelDispatch(backupProvider, backupPR)
					d.setLastInferenceError(backupProvider, errMsg2)
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					d.updateSpeculativeFailure(backupPR, errMsg2)
					d.noteDispatchRetry(backupProvider, backupPR, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &backupHeld)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					backupPR.BackupWon = true
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-backupPR.AcceptedCh:
			continue
		case errMsg2 := <-backupPR.ErrorCh:
			backupDeadline.Stop()
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = backupPR.RequestID
				d.heldChunks = backupHeld
				d.noteServingSlot()
				d.commitFirstContent(backupPR, chunk.Data)
				d.committed = true
				d.initialError = &errMsg2
				return outcomeCommitted
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.cancelDispatch(backupProvider, backupPR)
			d.setLastInferenceError(backupProvider, errMsg2)
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			d.updateSpeculativeFailure(backupPR, errMsg2)
			d.noteProviderError(backupProvider, backupPR, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &backupHeld)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-backupDeadline.C:
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if backupPR.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(backupHeld) > 0 && d.canExtendPreambleLiveness() {
				// Backup preamble liveness — promote it and continue
				// in waitAccepted on leftover first-token budget.
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.cancelDispatchForFirstContentTimeout(backupProvider, backupPR) {
				continue
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(
				backupPR, d.deadline-d.speculativeAt) {
				s.noteInferenceError(backupProvider.ID, backupPR, http.StatusGatewayTimeout, "", "", "")
			}
			d.updateSpeculativeTimeout(backupPR, "first_chunk_timeout")
			d.setLastError("timeout waiting for first response (backup)", http.StatusGatewayTimeout)
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			backupDeadline.Stop()
			d.updateSpeculativeClientGone(backupPR)
			s.cancelDispatch(backupProvider, backupPR)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// raceBackupErrWaitPrimary handles the race sub-case where the backup errored
// (already recorded): wait the remaining deadline for the primary. This is the
// former `backupFailedWaitPrimary` loop. d.provider/d.pr remain the primary.
func (d *dispatchState) raceBackupErrWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	primaryDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			primaryDeadline.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.setLastInferenceError(provider, errMsg2)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			continue
		case errMsg2 := <-pr.ErrorCh:
			primaryDeadline.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg2) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.setLastInferenceError(provider, errMsg2)
			d.lastFailedVersion = failedProviderVersion(provider)
			d.updateSpeculativeFailure(pr, errMsg2)
			d.noteProviderError(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-primaryDeadline.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Primary preamble liveness — continue in waitAccepted
				// on leftover request-absolute first-token budget.
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.cancelDispatchForFirstContentTimeout(provider, pr) {
				continue
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.updateSpeculativeTimeout(pr, "first_chunk_timeout")
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-r.Context().Done():
			primaryDeadline.Stop()
			d.updateSpeculativeClientGone(pr)
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// waitAccepted runs the post-accept wait for first content (the former
// `acceptedWait` loop). It is entered when the committed provider accepted or held
// preamble but hasn't produced content yet. Accept is not a completion token:
// the request-absolute first-token clock keeps running. preambleLiveness still
// caps the wait at preambleContentTimeout so a role-then-stall zombie fails
// over instead of pinning, but that cap cannot exceed leftover SLA.
func (d *dispatchState) waitAccepted() (outcome dispatchOutcome) {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr
	captured := routingAttempt(provider, pr, pr.RequestID, pr.Attempt)

	defer func() {
		target := d.currentOrCapturedRoutingAttempt(captured)
		switch outcome {
		case outcomeCommitted:
			d.updateRoutingOutcomeForAttempt(target, d.successRoutingOutcomeFor(target.pending))
		case outcomeRetry:
			// Synthetic-timeout 504s unless a KNOWN typed 504 cause — a typed
			// provider 504 keeps its provider-error class + usage; unknown
			// causes stay legacy (see waitFirstChunk).
			if d.lastErrCode == http.StatusGatewayTimeout && !isTypedTimeout504Cause(d.lastErrTerminalCause) {
				if d.preambleLiveness {
					d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "timeout", "preamble_liveness_timeout", d.lastErrCode))
				} else {
					d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "timeout", "accepted_timeout", d.lastErrCode))
				}
			} else {
				// Post-dispatch provider failure (incl. OOM/model-load): admitted but failed.
				d.updateRoutingOutcomeForAttempt(target, d.providerFailedRoutingOutcomeFor(target.pending))
			}
		case outcomeClientGone:
			d.emitClientGone(phaseBeforeFirstToken)
			d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "cancelled", "client_gone", 0))
		}
	}()

	firstContentBudget := inferenceTimeout
	if d.preambleLiveness {
		firstContentBudget = preambleContentTimeout
	}
	if remaining, ok := d.firstTokenRemaining(); ok && remaining < firstContentBudget {
		firstContentBudget = remaining
	}
	chunkTimer := time.NewTimer(firstContentBudget)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			chunkTimer.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				// Closed — check for error. Use a short grace
				// period instead of a non-blocking default to
				// close the race where Go's select picks the
				// ChunkCh close before the ErrorCh value (sent
				// by the provider handler before closing ChunkCh).
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					s.logger.Warn("provider failed after accepting request, retrying",
						"request_id", d.requestID,
						"provider_id", provider.ID,
						"attempt", d.attempt+1,
						"failure_code", errMsg.FailureCode,
					)
					s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
						"provider failed after accepting request, retrying",
						map[string]any{
							"provider_id": provider.ID,
							"attempt":     d.attempt + 1,
							"reason":      "provider_error",
							"status_code": errMsg.StatusCode,
						})
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
					}
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				case <-time.After(50 * time.Millisecond):
					d.committed = true
				}
			}
			return outcomeCommitted
		case errMsg := <-pr.ErrorCh:
			chunkTimer.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"failure_code", errMsg.FailureCode,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed after accepting request, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-chunkTimer.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if !s.cancelDispatchForFirstContentTimeout(provider, pr) {
				continue
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, firstContentBudget)
			// Accepted-then-silent (or preamble-then-stall) feeds the
			// breaker so a provider that repeatedly acks and stalls enters
			// cooldown — but ONLY when the provider was actually granted a
			// provider-attributable window. A budget capped short by the
			// request-absolute first-token clock is OUR deadline (queueing,
			// admission), not provider sickness.
			if providerAttemptAttributableStall(pr, firstContentBudget) {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.setLastError("provider accepted but timed out before first chunk", http.StatusGatewayTimeout)
			if d.preambleLiveness {
				d.setLastError("provider sent preamble but stalled before first content", http.StatusGatewayTimeout)
			}
			s.logger.Warn("provider timed out after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"preamble_liveness", d.preambleLiveness,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider accepted timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "accepted_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// run is the dispatch orchestrator. It replaces the giant inline `for attempt :=
// range maxDispatchAttempts { ... }` block plus the post-loop !committed ladder,
// attestation headers, timing header, settlement defer, and final response handoff.
func (d *dispatchState) run() {
	s := d.s
	defer d.finalizeProfile()
	w, r := d.w, d.r
	d.preflightLegacyCacheBust()

	for attempt := range maxDispatchAttempts {
		d.attempt = attempt
		// Deadline-bounded failover: after the first attempt, stop failing over
		// once the request's deadline/context has fired (client gone or a request
		// timeout). We keep trying fresh healthy providers only while there is
		// time budget left. Candidate exhaustion is handled inside dispatchPrimary
		// (it returns outcomeFailFast as soon as no eligible provider remains), so
		// in practice the loop ends at exhaustion or success; maxDispatchAttempts
		// is only a hot-loop ceiling and this is the wall-clock bound.
		if attempt > 0 && r.Context().Err() != nil {
			goto exhausted
		}
		if attempt > 0 && d.firstTokenExpired() {
			// The request-absolute first-token budget is gone: the client must
			// see the retryable 429 (synthetic 504 -> first_chunk_timeout), not
			// whatever the last provider attempt happened to fail with.
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			goto exhausted
		}
		// Each attempt holds preamble chunks from its own provider only.
		d.heldChunks = nil

		switch d.dispatchPrimary() {
		case outcomeRetry:
			continue
		case outcomeFailFast:
			goto exhausted
		case outcomeResponseWritten, outcomeClientGone:
			return
		case outcomeProceed:
			// fall through to the first-chunk wait below
		}

		d.requestID = d.pr.RequestID
		// d.pr.Attempt is already stamped at PendingRequest construction in
		// dispatchOneProvider (and on the queued path), before the provider send —
		// so it is never written here, where it would race handleComplete.
		if d.timing.RoutedAt.IsZero() {
			d.timing.RoutedAt = time.Now()
		}

		s.ddIncr("routing.decisions", []string{"model:" + d.model, "outcome:selected"})
		s.ddIncr("routing.provider_selected", []string{"provider_id:" + d.provider.ID, "model:" + d.model})

		s.logger.Info("inference request dispatched",
			"trace_id", requestIDFromContext(r.Context()),
			"request_id", d.requestID,
			"model", d.model,
			"provider_id", d.provider.ID,
			"stream", d.stream,
			"attempt", attempt+1,
		)

		s.logger.Info("dispatch_pool",
			"model", d.model,
			"ttft_deadline_ms", d.deadline.Milliseconds(),
			"speculative_at_ms", d.speculativeAt.Milliseconds(),
		)

		if d.firstTokenExpired() {
			// A token that is already buffered beats the clock: deliver it
			// instead of 429ing a request the provider answered on time.
			if chunk, ok := drainReadyFirstContent(d.pr, &d.heldChunks); ok {
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
				break
			}
			if d.abandonInflightForFirstTokenTimeout() {
				goto exhausted
			}
		}

		// ---- Speculative TTFT-aware first-chunk wait ----
		switch d.waitFirstChunk() {
		case outcomeRetry:
			// Post-dispatch provider failure. Stop failing over when the request is
			// unservable (deterministic context overflow, or a capacity transient
			// past maxCapacityClassRetries) so we don't storm all 64 providers; the
			// exhausted ladder then emits one uptime-neutral 429. Faults/timeouts
			// return false and keep failing over as before.
			if d.shouldStopFailover() {
				goto exhausted
			}
			continue
		case outcomeClientGone:
			return
		case outcomeAccepted:
			// Provider accepted or held preamble but hasn't produced content.
			switch d.waitAccepted() {
			case outcomeRetry:
				if d.shouldStopFailover() {
					goto exhausted
				}
				continue
			case outcomeClientGone:
				return
			}
		}

		break
	}

exhausted:
	if !d.committed {
		d.refundReservation()
		if d.providerBodyTooLargeErr != "" &&
			d.lastErrCode == http.StatusRequestEntityTooLarge {
			d.latchProviderBodyTooLarge(d.providerBodyTooLargeErr)
		}
		failure, stickyFault := d.terminalFailureForExhaustion()
		statusCode, reason, timeoutReclassified, dominance :=
			d.resolveDominantExhaustedStatus(failure, stickyFault)
		if timeoutReclassified {
			s.ddIncr("routing.first_chunk_timeout_reclassified", []string{"model:" + d.model})
		}
		switch dominance {
		case exhaustedClientError:
			// Deterministic provider client 4xx (identical fleet-wide): pass the real
			// code through ONCE. Checked BEFORE d.unservable / statusCode==0 so it can
			// never be reclassified to 429/503 — this is a client fault, not capacity.
			s.ddIncr("routing.client_error_passthrough", []string{"model:" + d.model, "code:" + strconv.Itoa(statusCode)})
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
			s.ddIncr("routing.oversized_request_rejected", []string{"model:" + d.model, "stage:dispatch"})
		case exhaustedDeadline:
			// Every refusal was health-neutral and did not consume the generic
			// capacity retry cap. Once no untried candidate remains, expose one
			// uptime-neutral 429 with its own closed reason.
			s.ddIncr("routing.deadline_unreachable_rejected", []string{"model:" + d.model, "stage:dispatch"})
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
			} else if statusCode >= 500 && isCapacityClassProviderError(failure.errText) {
				// Backstop (always on): the provider admitted the request then
				// rejected it because (prompt+max_tokens) overflowed its token budget /
				// KV / context — a capacity condition, not a server fault. Return an
				// uptime-neutral 429 (OpenRouter fails over) instead of the raw 5xx,
				// which would count against our uptime. Fires only on a real provider
				// rejection, so it cannot over-reject servable traffic.
				statusCode = http.StatusTooManyRequests
				reason = "unservable_token_budget"
				s.ddIncr("routing.unservable_reclassified", []string{"model:" + d.model})
			}
		}
		// Resolved once: the telemetry event and the OR-uptime counter must agree
		// on which slot's backend this failure belongs to, and on whether that
		// backend was chosen or degraded into (v0.8.0 paged rollout).
		kvBackend := d.exhaustedKVBackendAttribution(failure, stickyFault)
		s.emitRequest(r.Context(), protocol.SeverityError, d.requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", d.exhaustionAttemptCount()),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     d.exhaustionAttemptCount(),
				"status_code": statusCode,
				"last_error":  failure.errText,
				"kv_backend":  kvBackend.Backend,
			})
		if s.metrics != nil {
			s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "failure"})
		}
		s.ddIncr("inference.dispatches", []string{"status:failure"})
		// OR-uptime outcome for a dispatched-but-failed request (exactly once;
		// pre-dispatch rejections emit from recordRejection instead).
		d.recordDispatchedRequestOutcome(kvBackend, classifyOutcomeByCode(statusCode))
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
			if !stickyFault && (d.unservable || failure.deadline) {
				// No provider could serve this request (it exceeds the model
				// context, or every attempted provider refused the remaining
				// deadline). Mark it not-servable so the rejection ledger's
				// counterfactual reflects the terminal decision.
				info.servabilityComputed = true
				info.candidateCount = 0
			}
			s.recordRejection(info)
		} else {
			s.recordRejection(d.rejectionInfo("dispatch", reason, statusCode, 0))
		}
		rateLimitMessage := fmt.Sprintf(
			"all providers at capacity after %d attempt(s): %s",
			d.exhaustionAttemptCount(), failure.errText)
		if reason == rejectionReasonDeadlineUnreachable {
			rateLimitMessage = fmt.Sprintf(
				"no provider could produce first content within the remaining deadline for model %q",
				d.publicModel)
		}
		if statusCode == http.StatusTooManyRequests {
			writeJSON(w, statusCode, errorResponse("rate_limit_exceeded",
				rateLimitMessage,
				withCode("rate_limit_exceeded")))
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
				writeJSON(w, statusCode, errorResponse(
					"invalid_request_error", d.terminalClientErrorMessage, withCode(errorCode)))
			} else {
				writeJSON(w, statusCode, errorResponse("invalid_request_error", failure.errText))
			}
		} else {
			writeJSON(w, statusCode, errorResponse("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", d.exhaustionAttemptCount(), failure.errText)))
		}
		return
	}
	if s.metrics != nil {
		s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "success"})
	}
	s.ddIncr("inference.dispatches", []string{"status:success"})
	// OR-uptime outcome. For STREAMING this is a commit-time approximation (the
	// consumer got content; a later post-commit mid-stream failure is still counted
	// as success — the persisted route-outcome rows hold the exact breakdown). For
	// NON-streaming, "committed" only means a provider chunk arrived and the writer
	// can still fail with a 5xx/504, so the outcome is recorded in
	// writeCommittedResponse from the status it actually writes. Emitted exactly
	// once per dispatched request (disjoint from the exhausted branch above and
	// from pre-dispatch rejections).
	if d.stream {
		d.recordDispatchedRequestOutcome(d.kvBackendAttribution(), orClassSuccess)
	}

	d.writeCommittedResponse()
}

// writeCommittedResponse writes the provider attestation + timing headers, installs
// the park-before-remove settlement defer, and hands off to the streaming /
// non-streaming response writer. Extracted verbatim from the committed tail of the
// original handler.
// contentLatency is the time from dispatch to the first CONTENT chunk delivered
// to the client (FirstContentAt). It deliberately does NOT fall back to
// FirstChunkAt — that timestamp is also stamped on held role-only / lifecycle
// preamble, so using it would let a fast-preamble-then-stall provider (or a
// preamble-only clean close that produced no content) look artificially
// responsive. Returns 0 when no content was delivered or the timing is
// incomplete, which the caller treats as "no sample".
func contentLatency(t *registry.RequestTiming) time.Duration {
	if t == nil || t.DispatchedAt.IsZero() || t.FirstContentAt.IsZero() {
		return 0
	}
	if d := t.FirstContentAt.Sub(t.DispatchedAt); d > 0 {
		return d
	}
	return 0
}

// adjustLatencyForPrefill turns a raw time-to-first-content into the reputation
// latency sample by removing the prompt-size-dependent prefill. Time-to-first-
// token grows with the input length, so a provider serving long prompts would
// otherwise look slow purely because of its workload. Using the provider's own
// benchmarked prefill rate keeps the correction per-provider and free of
// hard-coded constants; what remains approximates queueing, scheduling,
// model-load and first-decode overhead. Returns 0 when there is no usable sample
// (which RecordLatency ignores), including when the prefill estimate exceeds the
// measured latency.
func adjustLatencyForPrefill(raw time.Duration, promptTokens int, prefillTPS float64) time.Duration {
	if raw <= 0 {
		return 0
	}
	if promptTokens > 0 && prefillTPS > 0 {
		raw -= time.Duration(float64(promptTokens) / prefillTPS * float64(time.Second))
	}
	if raw <= 0 {
		return 0
	}
	return raw
}

func shouldRecordReputationLatency(pr *registry.PendingRequest, firstChunk string) bool {
	return pr != nil && pr.Timing != nil && firstChunk != "" && !pr.CacheRoutingParticipates()
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
	if shouldRecordReputationLatency(pr, d.firstChunk) {
		// FirstContentAt was already stamped at the content-commit site
		// (commitFirstContent), earlier in THIS goroutine, so contentLatency reads
		// a set value here. No re-stamp needed; just read it for the reputation
		// latency sample.
		sample := adjustLatencyForPrefill(contentLatency(pr.Timing), pr.EstimatedPromptTokens, provider.PrefillTPS)
		// Provider-level: p.mu only. The registry-level form looks the
		// provider up under r.mu, and this runs before the first client write.
		provider.RecordLatency(sample)
	}

	// Write provider attestation headers now that we're committed. When the
	// caller opted into metadata_details, snapshot the same consumer-safe
	// fields onto the pending request so chat-completions writers can attach
	// them to the JSON body (OpenAI SDKs often hide custom headers).
	info := collectCommittedProviderInfo(provider)
	writeCommittedProviderHeaders(w, info)
	d.writeTimingHeaderWithProfile(w, pr)
	d.stampCommitted(pr)
	writeInferenceJobIDHeader(w, pr.RequestID)
	snapshotChatCompletionMetadata(pr, info)

	// On return (disconnect/timeout/completion): free the slot, tell the
	// provider to stop, and preserve billing for a mid-stream disconnect.
	// Park BEFORE RemovePending so a racing provider terminal always finds the
	// record in pending or the holder — never neither (which would drop it and
	// mis-refund). GetPending is nil if a terminal already settled it (normal
	// completion), so nothing is parked then. Both settle paths are
	// FinalizeReservation-guarded, so the park-then-remove overlap can't double-bill.
	defer func() {
		terminalSettled := true
		if stale := provider.GetPending(requestID); stale != nil {
			// The provider is still generating for a client that is gone: this
			// cancel is the one that stops real work, so stamp it.
			terminalSettled = false
			stale.Profile.Mark(registry.StampCancelSent)
			s.holdForSettlement(stale)
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
		provider.RemovePending(requestID) // then remove so SetProviderIdle frees the slot
		s.registry.SetProviderIdle(provider.ID)
		// A settled terminal means the provider already sent its completion or
		// error (or disconnected): there is no generation left to stop, so the
		// cancel frame — one marshal and one writer-lane WebSocket write per
		// completed request — is skipped. Only a still-pending request (the
		// client-gone / mid-stream exits above) gets the cancel.
		if !terminalSettled {
			s.sendProviderCancel(provider, requestID)
		}
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
		// statusWriter (server.go) captures the WriteHeader code and transparently
		// delegates Flush/Hijack/Unwrap, so wrapping preserves the writer's
		// capabilities; zero-valued status starts at 0 (uncounted).
		sw := &statusWriter{ResponseWriter: w}
		s.handleNonStreamingResponseWithFirstChunkAndError(
			sw, r, pr, firstChunks, d.initialError)
		switch {
		case sw.status == http.StatusOK:
			d.recordDispatchedRequestOutcome(d.kvBackendAttribution(), orClassSuccess)
		case sw.status > 0:
			d.recordDispatchedRequestOutcome(
				d.kvBackendAttribution(), classifyOutcomeByCode(sw.status))
		}
	}
}
