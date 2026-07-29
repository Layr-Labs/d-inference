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
	"encoding/json"
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
	// outcomeAccepted: the provider signalled AcceptedCh / preamble liveness but
	// has not produced content yet. The orchestrator proceeds to waitAccepted.
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
	stream                 bool
	policy                 selfRoutePolicy
	allowedProviderSerials []string
	cachePlan              registry.CachePlan
	timing                 *registry.RequestTiming
	deadline               time.Duration
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
	// lastErrTerminalCause is the typed terminal_cause from the last provider
	// error ("" for legacy providers). shouldStopFailover trusts a typed
	// admission_timeout as transient capacity directly — the provider's engine
	// TOLD us it was busy — instead of inferring from error-string substrings
	// that the fixed "admission_timeout: …" text would never match.
	lastErrTerminalCause string
	// lastErrAttemptUsage is the typed partial usage from the last provider
	// error (nil for legacy providers), applied to the failed attempt's route
	// row by providerFailedRoutingOutcomeFor so pre-content typed failures on
	// the ordinary dispatch path keep their observability data.
	lastErrAttemptUsage *protocol.UsageInfo
	committed           bool
	// keepalive emits SSE keepalive comments during a long prefill once the
	// request has been dispatched, committing HTTP 200 early so the consumer
	// connection does not time out. nil when disabled or non-streaming.
	keepalive         *prefillKeepaliver
	lastFailedVersion string
	excludeProviders  map[string]struct{}
	// capacityRetries counts pre-content TRANSIENT-capacity failovers (this
	// node's live KV budget, a full queue, a drain). Bounded by
	// maxCapacityClassRetries so a fleet-wide transient cannot storm; a
	// DETERMINISTIC-context rejection (prompt > model context) stops on the first
	// attempt regardless (see classifyRejection / failoverOutcome).
	capacityRetries int
	// unservable is set when the dispatch loop stops because the request cannot
	// be served (deterministic-context rejection, or a transient that exhausted
	// maxCapacityClassRetries). The exhausted ladder then emits a single
	// uptime-neutral 429 with unservableReason instead of retrying/5xx'ing.
	unservable       bool
	unservableReason string
	// lastDecision is the most recent scheduler decision that carried signal
	// (a selection, or a scan that saw candidates / capacity rejections). The
	// exhausted ladder reports its counters in the rejection ledger, so a
	// "could_have_served" verdict is computed from what the scheduler actually
	// saw instead of being hard-written to zero. Attempts whose scan found
	// nothing at all do not overwrite it: an empty tail decision would erase
	// the evidence of the providers earlier attempts really did try.
	lastDecision registry.RoutingDecision
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
	// servedKVBackend latches the KV-cache backend attribution of the SLOT the
	// most recent attempt was dispatched to (v0.8.0 paged rollout, Gate G5) —
	// the resolved kind AND whether that kind was a silent degrade. It is NOT
	// per-attempt scratch: the failure tails run after a retry has cleared
	// d.provider/d.pr, and a 5xx from a paged slot that just fell over is
	// exactly the sample the rollout dashboard must not lose. Zero value until
	// the request reaches a slot, which tags unknown on both dimensions.
	servedKVBackend kvBackendAttribution
	// The (provider, model) the latch above was taken for. Not decoration: it
	// is what lets kvBackendAttribution reuse the latch instead of re-entering
	// the registry, while still honouring the rule that a LIVE d.pr wins — a
	// speculative backup that beats the primary must be attributed to the
	// backup's slot, and that shows up here as a key mismatch.
	servedKVProviderID string
	servedKVModel      string

	// ---- per-attempt scratch (reset each attempt) ----
	attempt          int
	accepted         bool
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
	// The return says whether the pair's capacity-503 RATE window stored this
	// accept. The enabled tracker retains it even before the first reject; stamp
	// the request so completion cannot add the same denominator outcome twice.
	if d.s.registry.RecordCapacityAccept(pr.ProviderID, pr.Model) {
		pr.MarkRateOutcomeCounted()
	}
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
	// Same bleed-through rule for the typed terminal fields: a coordinator-
	// synthesized error is not a provider terminal, so a stale typed cause from
	// a prior attempt must not reclassify it (shouldStopFailover trusts a typed
	// admission_timeout as transient capacity) and stale usage must not land on
	// its route row. An empty cause here is also what lets the wait loops'
	// 504 branches tell a synthetic timeout from a typed provider 504.
	d.lastErrTerminalCause = ""
	d.lastErrAttemptUsage = nil
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
	d.lastErr = msg.Error
	d.lastErrCode = msg.StatusCode
	d.lastErrReason = msg.ErrorReason
	d.lastErrProviderBudget = providerReportedBudget(provider, d.model)
	d.lastErrTerminalCause = msg.TerminalCause
	d.lastErrAttemptUsage = msg.AttemptUsage
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
	if providerDisconnectedError(d.lastErr, d.lastErrCode) {
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
	case "failed to send request to provider":
		return "provider_error"
	default:
		if errText == "" {
			return "provider_error"
		}
		return "provider_error"
	}
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

// noteDecision latches a scheduler decision for the exhausted ladder's
// rejection telemetry. Only decisions that carry signal are kept — a later
// attempt whose scan found nothing (every provider already excluded, say) must
// not erase what earlier attempts saw.
func (d *dispatchState) noteDecision(decision registry.RoutingDecision) {
	if decision.ProviderID != "" || decision.CandidateCount > 0 ||
		decision.CapacityRejections > 0 || decision.ModelTooLargeRejections > 0 ||
		decision.VisionRejections > 0 {
		d.lastDecision = decision
	}
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

// exhaustedRejectionInfo builds the rejection-ledger record for the exhausted
// dispatch ladder's 429/503 exit. The counterfactual it carries is what
// recordRejection turns into could_have_served, so the three exits must not
// share one shape:
//
//   - CAPACITY RETRIES EXHAUSTED: the fleet could have served this request and
//     was merely full. Report the scheduler's real counters, with candidateCount
//     floored by the number of providers that actually capacity-rejected a
//     dispatched attempt — each of those was by definition a candidate when it
//     was selected, so the floor cannot over-report, and it keeps a decision
//     that happens to carry no counters from under-reporting below what the
//     loop itself observed. This path previously hard-wrote candidateCount = 0,
//     which booked every busy-fleet rejection as "could not have served" — the
//     misreporting that sent the 2026-07 incident diagnosis down the wrong path
//     for an hour.
//
//     capacityRejections is deliberately NOT floored the same way. It counts
//     candidates the admission gate shed DURING SELECTION, never dispatched;
//     d.capacityRetries counts providers that WERE dispatched and returned a
//     capacity 503. Those are disjoint halves of the funnel, and maxing them
//     into one field would reintroduce exactly the counter conflation this
//     change exists to remove. The dispatched count is recoverable from
//     candidateCount, which the floor makes honest.
//
//   - DETERMINISTICALLY UNSERVABLE: candidates existed and every one of them
//     would reject the same request identically, so zero is the honest answer
//     and it is stated authoritatively (mirroring the preflight gate).
//
//   - EVERYTHING ELSE: leave servabilityComputed false and let recordRejection
//     compute the counterfactual itself off the request path.
func (d *dispatchState) exhaustedRejectionInfo(reason string, statusCode, retryAfterMs int) rejectionInfo {
	if !d.unservable {
		return d.rejectionInfo("dispatch", reason, statusCode, retryAfterMs)
	}
	if reason != rejectionReasonCapacityRetriesExhausted {
		info := d.rejectionInfo("dispatch", reason, statusCode, retryAfterMs)
		info.servabilityComputed = true
		info.candidateCount = 0
		return info
	}
	info := d.rejectionInfoWithDecision("dispatch", reason, statusCode, retryAfterMs, d.lastDecision)
	if info.candidateCount < d.capacityRetries {
		info.candidateCount = d.capacityRetries
	}
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
	d.provider, d.pr, decision, dispatchErr, dispatchErrCode = s.dispatchOneProvider(
		r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
		d.estimatedPromptTokens, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
		d.traits(),
		d.allowedProviderSerials, d.isResponsesAPI, d.policy, d.timing, d.serviceReservation, d.cachePlan, d.excludeProviders,
		d.attempt,
		func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
			routeProvider = provider
			routeRecorded = true
			if pr != nil {
				routeRequestID = pr.RequestID
				routeAttempt = pr.Attempt
			}
			d.recordRoutingDecisionFor(provider, pr, routeRequestID, routeAttempt, decision, "", "")
		},
	)
	d.dispatchErr = dispatchErr
	d.dispatchErrCode = dispatchErrCode
	d.noteDecision(decision)
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

		// Providers are available but all exceed the TTFT ceiling. This
		// rejection is deterministic — the scheduler computes it from the same
		// fleet-wide estimate on every scan — so retrying the reservation
		// within this request cannot succeed. Fail fast with a retryable 429
		// on ANY attempt (kill switch: EIGENINFERENCE_TTFT_TERMINAL_REJECT=
		// false restores the legacy attempt-0-only fast path, under which a
		// mid-ladder rejection looped to maxDispatchAttempts re-running the
		// doomed scan). Nothing has been committed to the client at a
		// reservation failure except, possibly, a prefill keepalive's HTTP
		// 200 from an earlier attempt — the status code is then frozen, so
		// route that case through the exhausted ladder, which surfaces the
		// 429 in-band exactly once. takeOver() also guarantees no keepalive
		// goroutine can commit the SSE 200 while the 429 below is written.
		if dispatchErr == errTTFTTooSlow && (attempt == 0 || ttftTerminalRejectEnabled()) {
			if attempt > 0 && d.keepalive.takeOver() {
				d.setLastError(dispatchErr, dispatchErrCode)
				return outcomeFailFast
			}
			bestTTFT := time.Duration(decision.BestTTFTMs * float64(time.Millisecond))
			d.refundReservation()
			if attempt > 0 {
				// The legacy loop's exhausted ladder wrote ONE request_rejections
				// row and ONE OR-uptime outcome for a mid-ladder TTFT storm; keep
				// both (the attempt-0 path emits neither, unchanged).
				retryAfter := s.estimateTTFTRetryAfter(d.model, bestTTFT, d.deadline)
				s.recordRejection(d.rejectionInfoWithDecision("dispatch", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, decision))
				s.recordRequestOutcome(d.model, d.kvBackendAttribution(), classifyOutcomeByCode(http.StatusTooManyRequests))
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
			MaxTTFTMs:              queueMaxTTFTMs(d.policy, d.deadline, d.s.ttftHardReject),
			MinDecodeTPS:           d.s.minDecodeTPS,
			AcceptedCh:             make(chan struct{}, 1),
			ChunkCh:                make(chan string, chunkBufferSize),
			CompleteCh:             make(chan protocol.UsageInfo, 1),
			ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
			Timing:                 d.timing,
		}
		queuedReq := &registry.QueuedRequest{
			RequestID:  d.requestID,
			Model:      d.model,
			Pending:    queuePR,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		queuePR.Timing.QueuedAt = time.Now()
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			s.ddIncr("routing.decisions", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model), "outcome:over_capacity"})
			retryAfter := s.estimateRetryAfter(d.model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			d.refundReservation()
			s.recordRejection(d.rejectionInfoWithDecision("queue", "queue_full", http.StatusTooManyRequests, retryAfter*1000, decision))
			if d.policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", d.publicModel),
					withCode("rate_limit_exceeded")))
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
		d.provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				s.recordWarmPoolQueueState(d.model)
				d.emitClientGone(phaseBeforeFirstToken)
				d.updateRoutingOutcome(d.errorRoutingOutcome("cancelled", "client_gone", 0))
				d.refundReservation()
				return outcomeClientGone
			}
			if errors.Is(err, registry.ErrQueueTTFTTooSlow) {
				// The drain proved every eligible provider fails ONLY the TTFT
				// ceiling — deterministic, so answer with the standard
				// ttft_too_slow 429 instead of waiting out the queue.
				s.recordWarmPoolQueueState(d.model)
				d.updateRoutingOutcome(d.errorRoutingOutcome("error", "ttft_too_slow", http.StatusTooManyRequests))
				d.refundReservation()
				s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
				s.triggerWarmPool()
				bestTTFT := time.Duration(queuedReq.Decision.BestTTFTMs * float64(time.Millisecond))
				retryAfter := s.estimateTTFTRetryAfter(d.model, bestTTFT, d.deadline)
				s.recordRejection(d.rejectionInfoWithDecision("queue", "ttft_too_slow", http.StatusTooManyRequests, retryAfter*1000, queuedReq.Decision))
				s.writeTTFTTooSlow(w, d.model, d.publicModel, bestTTFT, d.deadline)
				return outcomeResponseWritten
			}
			if errors.Is(err, registry.ErrQueueToolConstraintUnavailable) {
				s.recordWarmPoolQueueState(d.model)
				d.updateRoutingOutcome(d.errorRoutingOutcome(
					"error", "model_capability_unsupported",
					http.StatusServiceUnavailable))
				d.refundReservation()
				s.recordRejection(d.rejectionInfoWithDecision(
					"queue", "model_capability_unsupported",
					http.StatusServiceUnavailable, 0, queuedReq.Decision))
				writeJSON(w, http.StatusServiceUnavailable, errorResponse(
					"model_unavailable",
					fmt.Sprintf(
						"no online provider for model %q supports inference-time tool_choice enforcement",
						d.publicModel),
					withParam("model")))
				return outcomeResponseWritten
			}
			d.updateRoutingOutcome(d.errorRoutingOutcome("timeout", "queue_timeout", http.StatusTooManyRequests))
			d.refundReservation()
			s.ddIncr("request_queue.timeout", []string{"model:" + d.model, "model_type:" + s.registry.ModelType(d.model)})
			s.registry.RecordWarmPoolQueueTimeout(d.model, time.Since(queuedReq.EnqueuedAt))
			retryAfter := s.estimateRetryAfter(d.model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			s.recordRejection(d.rejectionInfoWithDecision("queue", "queue_timeout", http.StatusTooManyRequests, retryAfter*1000, decision))
			if d.policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity (timed out waiting for a free slot) — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", d.publicModel),
					withCode("rate_limit_exceeded")))
			}
			return outcomeResponseWritten
		}
		s.recordWarmPoolQueueState(d.model)
		// Queue assigned a provider; still need to dispatch.
		// Use the queue PR's channels.
		d.pr = queuePR
		d.requestID = d.pr.RequestID
		d.timing.RoutedAt = time.Now()
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
		wireMsg := providerInferenceWireMessage(
			d.requestID, encrypted.EphemeralPublicKey, encrypted.Ciphertext, d.pr)
		d.pr.SessionPrivKey = &sessionKeys.PrivateKey
		// pr.ReservedMicroUSD was already set in the struct literal and may
		// have been increased by reserveAdditionalForProvider. Don't overwrite.
		data, err := json.Marshal(wireMsg)
		if err != nil {
			s.registry.ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.setLastError("failed to marshal request", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
		d.pr.Timing.DispatchedAt = time.Now()
		if err := writeProviderInferenceRequest(r.Context(), d.provider, data); err != nil {
			s.registry.ForgetCacheAttempt(d.pr)
			d.provider.RemovePending(d.requestID)
			s.registry.SetProviderIdle(d.provider.ID)
			s.refundProviderExtra(d.pr)
			d.excludeProviders[d.provider.ID] = struct{}{}
			d.setLastError("failed to send request to provider", 0)
			d.updateRoutingOutcome(d.errorRoutingOutcome("error", "provider_error", 0))
			return outcomeRetry
		}
	}
	// The request is now on a slot. Latch that slot's KV backend so the
	// exhaustion ladder can still attribute the outcome after a failover has
	// cleared d.provider/d.pr (v0.8.0 paged rollout, Gate G5).
	d.noteServingSlot()
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
// noteDispatchProviderError. When the structured error_reason proves a
// NON-provider fault (isNonProviderFaultErrorReason: jinja_* template-render
// failures, tool_noncompliance), the provider is withheld from the call so
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
// so capacity rejections (token_budget_exhausted / queue_full / cold "not
// loaded" misses, with or without a structured reason) flow through
// unchanged and the capacity-reject cooldown still sees every legitimate
// 503/404. The attempt's reservation-top-up refund and held-chunk discard
// (with its retry_precontent counter) run for EVERY reason:
// noteDispatchProviderError only feeds noteInferenceError for a non-nil
// provider, while the refund + held handling are unconditional.
func (d *dispatchState) noteProviderError(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string) (discardedHeld bool) {
	if isNonProviderFaultErrorReason(errReason) {
		provider = nil
	}
	return d.s.noteDispatchProviderError(provider, pr, statusCode, errStr, errReason, terminalCause, held)
}

// rejectionReasonOversized is the rejection-ledger reason_code for a request
// the dispatch loop stopped because it is DETERMINISTICALLY unservable — a
// context overflow that every provider in the fleet would reject identically.
// Distinct from the preflight "context_exceeded" / "prompt_too_long" and the
// legacy dispatch-exhausted "unservable_token_budget".
//
// Reserved for genuinely-unservable SHAPES. It used to double as the code for
// a transient-capacity shortage that exhausted maxCapacityClassRetries, which
// is a statement about the fleet being busy, not about the request — see
// rejectionReasonCapacityRetriesExhausted.
const rejectionReasonOversized = "oversized_request"

// rejectionReasonCapacityRetriesExhausted is the rejection-ledger reason_code
// for a request the dispatch loop stopped because it burned
// maxCapacityClassRetries (3) TRANSIENT-capacity failovers. The three
// providers it tried were candidates that were merely full; a fourth might
// have served it, and the same request an hour later on an idle fleet
// certainly would.
//
// Split out of rejectionReasonOversized deliberately. Conflating the two makes
// a busy fleet indistinguishable from an unservable request in the rejection
// ledger, which is precisely how the 2026-07 paged-rollout incident was
// misdiagnosed: ~10% of traffic booked as "oversized_request" when the prompts
// were ordinary and the boxes were simply out of KV pool.
const rejectionReasonCapacityRetriesExhausted = "capacity_retries_exhausted"

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
//   - genuine fault / timeout / unrecognised: return false → existing fault
//     failover (the per-provider breaker quarantines a persistently-sick node).
//
// When it returns true it sets d.unservable + d.unservableReason so the exhausted
// ladder emits exactly one uptime-neutral 429 (not a storm, not a raw 5xx). It is
// a no-op (returns false, no counters) for non-capacity outcomes, so timeouts and
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
	// Typed-cause override (highest-fidelity signal): a provider that attaches
	// terminal_cause=admission_timeout is TELLING us its engine was too busy to
	// admit the request within the admission lease — definitionally a
	// this-node transient-capacity condition (a healthier/idler provider may
	// serve). Without this, the fixed "admission_timeout: …" error text falls
	// through the legacy capacity substrings, gets classified as a generic
	// fault, and walks the unbounded fault-failover ladder to a final 503
	// instead of the bounded capacity retries and uptime-neutral 429.
	kind := classifyRejection(d.lastErrReason, d.lastErr, d.lastErrProviderBudget, d.modelMaxContext)
	if d.lastErrTerminalCause == terminalCauseAdmissionTimeout {
		kind = rejectionTransientCapacity
	}
	switch kind {
	case rejectionDeterministicUnservable:
		d.s.ddIncr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:deterministic"})
		d.unservable = true
		d.unservableReason = rejectionReasonOversized
		return true
	case rejectionTransientCapacity:
		d.s.ddIncr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:transient"})
		d.capacityRetries++
		if d.capacityRetries >= maxCapacityClassRetries {
			// Out of retries, NOT out of servability: every one of these
			// rejections came from a provider that was a real candidate and
			// simply had no KV room right now. The ladder still stops (a
			// fleet-wide transient must not storm 64 providers) and still
			// emits the uptime-neutral 429, but under its own reason code so
			// the ledger can tell a busy fleet from an unservable request.
			d.unservable = true
			d.unservableReason = rejectionReasonCapacityRetriesExhausted
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
	budget := providerReportedBudget(provider, d.model)
	if classifyRejection(msg.ErrorReason, msg.Error, budget, d.modelMaxContext) == rejectionDeterministicUnservable {
		d.s.ddIncr("routing.dispatch_to_capacity_503", []string{"model:" + d.model, "reason:deterministic"})
		d.unservable = true
		d.unservableReason = rejectionReasonOversized
		d.latchTerminalAttribution(provider)
	}
}

// waitFirstChunk runs the speculative TTFT-aware first-chunk wait (the former
// `firstChunkWait` labeled loop). It holds preamble chunks, commits on first
// content, extends on AcceptedCh / preamble liveness, retries invisibly on
// provider error/timeout, and launches the speculative backup race when the
// primary is slow. Returns outcomeCommitted (content / clean close), outcomeAccepted
// (cold-load or preamble liveness — proceed to waitAccepted), outcomeRetry
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

	speculativeTimer := time.NewTimer(d.speculativeAt)
	deadlineTimer := time.NewTimer(d.deadline)
	d.accepted = false
	// preambleLiveness distinguishes WHY the extended first-content wait was
	// entered: a genuine AcceptedCh (cold model load — keeps the full
	// inferenceTimeout) vs a held-boilerplate liveness extension past an
	// expired TTFT deadline (zero bytes written to the client — bounded by
	// preambleContentTimeout so a role-then-stall zombie fails over).
	d.preambleLiveness = false

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				d.commitFirstContent(pr, chunk)
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
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			d.accepted = true
			return outcomeAccepted

		case errMsg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"error", errMsg.Error,
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

		case <-speculativeTimer.C:
			deadlineTimer.Stop()
			return d.runSpeculative()

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			if len(d.heldChunks) > 0 {
				// Preamble liveness — the provider is alive but still in its
				// pre-content phase. Fall through to the extended
				// (preambleContentTimeout) wait instead of failing the attempt.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
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

	if !skipBackup {
		backupExclude := make(map[string]struct{}, len(d.excludeProviders)+1)
		for id := range d.excludeProviders {
			backupExclude[id] = struct{}{}
		}
		backupExclude[provider.ID] = struct{}{}

		backupProvider, backupPR, _, backupErr, backupErrCode = s.dispatchOneProvider(
			r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
			d.estimatedPromptTokens, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
			d.traits(),
			d.allowedProviderSerials, d.isResponsesAPI, d.policy,
			&registry.RequestTiming{ReceivedAt: d.timing.ReceivedAt},
			d.serviceReservation,
			d.cachePlan,
			backupExclude,
			d.attempt,
			func(provider *registry.Provider, pr *registry.PendingRequest, decision registry.RoutingDecision) {
				attemptedBackupProvider = provider
				if pr != nil {
					backupRouteRecorded = true
					backupRouteRequestID = pr.RequestID
					backupRouteAttempt = pr.Attempt
				}
				d.recordRoutingDecisionFor(provider, pr, "", d.attempt, decision, "", "")
			},
		)
	}

	if backupProvider == nil {
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
	return d.runRace(backupProvider, backupPR)
}

// waitNoBackup is the speculative-no-backup branch (`noBackupWait`): keep waiting
// for the primary alone with the remaining deadline. d.provider / d.pr are the primary.
func (d *dispatchState) waitNoBackup() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	remainingDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			remainingDeadline.Stop()
			if ok {
				d.commitFirstContent(pr, chunk)
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
			remainingDeadline.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg := <-pr.ErrorCh:
			remainingDeadline.Stop()
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
			if len(d.heldChunks) > 0 {
				// Liveness: the provider already produced its preamble —
				// vision prefill / template render may legitimately
				// exceed the TTFT deadline. Fall through to the
				// extended (preambleContentTimeout) wait for first
				// content, with ErrorCh still armed for retry.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
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

// runRace is the speculative `race` loop: primary (d.provider/d.pr) vs backup,
// first CONTENT chunk wins; the loser is cancelled. Preamble from each racer is
// buffered separately (held chunks must never mix providers). On a racer error the
// surviving racer is waited on via a sub-loop. Returns the waitFirstChunk outcome
// set; on a backup win d.provider/d.pr/d.requestID/d.heldChunks are swapped to the backup.
func (d *dispatchState) runRace(backupProvider *registry.Provider, backupPR *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	raceDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	// One-shot extension: when the race deadline expires but a racer
	// has shown liveness (preamble received), the race continues for
	// the full inference window instead of failing the request.
	raceExtended := false
	// Preamble chunks from the backup are buffered separately —
	// held chunks must never mix providers.
	var backupHeld []string

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				// Preamble only — the primary hasn't proven it can
				// generate; keep the backup racing for first content.
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			// Primary wins!
			raceDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			if ok {
				d.markSpeculativeLoser(backupPR)
				d.commitFirstContent(pr, chunk)
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
			if ok && len(backupHeld) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				// Backup preamble doesn't win the race — first CONTENT does.
				backupHeld = append(backupHeld, chunk)
				backupPR.MarkFirstChunkArrived()
				continue
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
				d.commitFirstContent(d.pr, chunk)
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

		case <-pr.AcceptedCh:
			// Primary accepted (model reload). Cancel backup, extend deadline.
			raceDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			d.markSpeculativeLoser(backupPR)
			d.accepted = true
			return outcomeAccepted

		case <-backupPR.AcceptedCh:
			// Backup accepted (model reload). Cancel primary, extend deadline.
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.markSpeculativeLoser(pr)
			backupPR.BackupWon = true
			d.provider = backupProvider
			d.pr = backupPR
			d.requestID = d.pr.RequestID
			d.heldChunks = backupHeld
			// The backup is the serving slot from here on: an accepted-wait
			// failure clears d.pr, and the terminal fallback must read the
			// backup's backend, not the cancelled primary's.
			d.noteServingSlot()
			d.accepted = true
			return outcomeAccepted

		case errMsg := <-pr.ErrorCh:
			// Primary failed. Keep waiting for backup.
			raceDeadline.Stop()
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
			return d.racePrimaryFailedWaitBackup(backupProvider, backupPR, backupHeld)

		case errMsg := <-backupPR.ErrorCh:
			// Backup failed. Keep waiting for primary.
			raceDeadline.Stop()
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.cancelDispatch(backupProvider, backupPR)
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			d.updateSpeculativeFailure(backupPR, errMsg)
			d.noteProviderError(backupProvider, backupPR, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &backupHeld)
			// Preserve a deterministic-unservable verdict from this loser so the
			// surviving primary's error can't mask it (see latchDeterministicLoser).
			d.latchDeterministicLoser(backupProvider, errMsg)
			return d.raceBackupErrWaitPrimary(provider, pr)

		case <-raceDeadline.C:
			if !raceExtended && (len(d.heldChunks) > 0 || len(backupHeld) > 0) {
				// Liveness from at least one racer: don't fail at the
				// TTFT deadline — extend once by the preamble-to-content
				// budget (zero bytes have reached the client; a genuine
				// cold load would have signalled AcceptedCh) and keep both
				// racing for first content, with both error channels still
				// armed for retry.
				raceExtended = true
				raceDeadline = time.NewTimer(preambleContentTimeout)
				continue
			}
			// Both missed deadline. A racer that held preamble (role
			// then stall) is a 504-shaped sickness — feed the breaker
			// before cancelling, mirroring the single-provider
			// acceptedWait timeout path so a stalling provider/model
			// (shape-keyed) trips its cooldown.
			if len(d.heldChunks) > 0 {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			if len(backupHeld) > 0 {
				s.noteInferenceError(backupProvider.ID, backupPR, http.StatusGatewayTimeout, "", "", "")
			}
			s.cancelDispatch(provider, pr)
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(backupProvider, backupPR)
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
	remainingPrimary := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			remainingPrimary.Stop()
			if ok {
				d.commitFirstContent(pr, chunk)
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
			remainingPrimary.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-pr.ErrorCh:
			// Defensive: both ErrorCh senders currently send before
			// closing ChunkCh (the closed-ChunkCh check above catches
			// them), but a direct arm keeps this loop correct if that
			// ordering ever changes — mirroring its sibling wait loops.
			remainingPrimary.Stop()
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
			if len(d.heldChunks) > 0 {
				// Primary preamble liveness — extend to the
				// preamble-to-content budget instead of failing.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			// The PRIMARY timed out here (the backup's earlier error
			// is already recorded); report the timeout, not the
			// backup's stale error text.
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
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
	backupDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-backupPR.ChunkCh:
			if ok && len(backupHeld) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				backupHeld = append(backupHeld, chunk)
				backupPR.MarkFirstChunkArrived()
				continue
			}
			backupDeadline.Stop()
			if ok {
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.commitFirstContent(d.pr, chunk)
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
			backupDeadline.Stop()
			backupPR.BackupWon = true
			d.provider = backupProvider
			d.pr = backupPR
			d.requestID = d.pr.RequestID
			d.heldChunks = backupHeld
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-backupPR.ErrorCh:
			backupDeadline.Stop()
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
			if len(backupHeld) > 0 {
				// Backup preamble liveness — promote it and extend
				// by the preamble-to-content budget for first content.
				backupPR.BackupWon = true
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(backupProvider, backupPR)
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
	primaryDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			primaryDeadline.Stop()
			if ok {
				d.commitFirstContent(pr, chunk)
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
			primaryDeadline.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-pr.ErrorCh:
			primaryDeadline.Stop()
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
			if len(d.heldChunks) > 0 {
				// Primary preamble liveness — extend by the
				// preamble-to-content budget instead of failing.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
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
// preamble but hasn't produced content yet. The budget depends on WHY we're here:
// a genuine AcceptedCh (model reload — legitimately minutes) keeps the full
// inferenceTimeout; a boilerplate-liveness extension past an expired TTFT deadline
// gets only preambleContentTimeout (zero bytes written to the client, so a
// preamble-then-stall provider must fail over instead of pinning for 10 minutes).
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
	chunkTimer := time.NewTimer(firstContentBudget)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			chunkTimer.Stop()
			if ok {
				d.commitFirstContent(pr, chunk)
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
						"error", errMsg.Error,
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
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"error", errMsg.Error,
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
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, firstContentBudget)
			s.cancelDispatch(provider, pr)
			// Accepted-then-silent (or preamble-then-stall) is a
			// provider-at-fault 504 — feed the breaker so a provider
			// that repeatedly acks and stalls enters cooldown instead
			// of soaking retries forever. (504 is one of the breaker's
			// counted codes; this arm is where those 504s originate.)
			s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
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
	w, r := d.w, d.r
	d.preflightLegacyCacheBust()

	// Stop any prefill keepalive goroutine on every exit path. Idempotent and
	// nil-safe (no-op when keepalives are disabled or the writer already took over).
	defer func() { d.keepalive.takeOver() }()

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

		// Now that the request is dispatched to a provider, start prefill SSE
		// keepalives for streaming requests so a long prefill does not leave the
		// consumer connection idle (OpenRouter's fetch timeout would otherwise fire
		// and fail us over). Started once; it persists across retries/speculation
		// and is taken over by the response writer when the first chunk commits.
		if d.stream && d.keepalive == nil && s.prefillKeepaliveInterval > 0 {
			d.keepalive = s.newPrefillKeepaliver(w, d.requestID)
			d.keepalive.start(r.Context())
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
		// Stop any prefill keepalive and learn whether it already committed HTTP
		// 200. Once committed, a status-coded error can no longer be sent — the
		// failure goes out in-band as an SSE error event instead.
		keepaliveCommitted := d.keepalive.takeOver()
		if d.providerBodyTooLargeErr != "" &&
			d.lastErrCode == http.StatusRequestEntityTooLarge {
			d.latchProviderBodyTooLarge(d.providerBodyTooLargeErr)
		}
		statusCode := d.lastErrCode
		reason := "dispatch_exhausted"
		if d.terminalClientError {
			// Deterministic provider client 4xx (identical fleet-wide): pass the real
			// code through ONCE. Checked BEFORE d.unservable / statusCode==0 so it can
			// never be reclassified to 429/503 — this is a client fault, not capacity.
			statusCode = d.terminalClientErrorCode
			reason = "client_error"
			if d.terminalClientErrorReason != "" {
				// The jinja_* stop records its own ledger reason
				// (template_render_failed) so template-render rejections stay
				// distinguishable from generic client-shape 4xxs.
				reason = d.terminalClientErrorReason
			}
			s.ddIncr("routing.client_error_passthrough", []string{"model:" + d.model, "code:" + strconv.Itoa(statusCode)})
		} else if d.unservable {
			// The loop stopped early: either no provider can serve this request
			// (deterministic context overflow) or a capacity transient exhausted
			// maxCapacityClassRetries. We already know the verdict, so skip the
			// quick-capacity probe and the 5xx→429 reclassification below: emit a
			// single uptime-neutral 429. This is the proactive complement to the
			// always-on backstop — it converts the request BEFORE storming the
			// fleet, not after 64 attempts. The two verdicts carry DIFFERENT
			// reason codes and different metrics (an unservable shape is a
			// property of the request; exhausted capacity retries are a property
			// of the fleet), so the ledger and the dashboards can tell them apart.
			statusCode = http.StatusTooManyRequests
			reason = d.unservableReason
			if reason == "" {
				reason = rejectionReasonOversized
			}
			if reason == rejectionReasonCapacityRetriesExhausted {
				s.ddIncr("routing.capacity_retries_exhausted", []string{"model:" + d.model, "stage:dispatch"})
			} else {
				s.ddIncr("routing.oversized_request_rejected", []string{"model:" + d.model, "stage:dispatch"})
			}
		} else if statusCode == 0 {
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
		} else if statusCode >= 500 && isCapacityClassProviderError(d.lastErr) {
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
		// Resolved once: the telemetry event and the OR-uptime counter must agree
		// on which slot's backend this failure belongs to, and on whether that
		// backend was chosen or degraded into (v0.8.0 paged rollout).
		kvBackend := d.kvBackendAttribution()
		s.emitRequest(r.Context(), protocol.SeverityError, d.requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", d.attempt+1),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     d.attempt + 1,
				"status_code": statusCode,
				"last_error":  d.lastErr,
				"kv_backend":  kvBackend.Backend,
			})
		if s.metrics != nil {
			s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "failure"})
		}
		s.ddIncr("inference.dispatches", []string{"status:failure"})
		// OR-uptime outcome for a dispatched-but-failed request (exactly once;
		// pre-dispatch rejections emit from recordRejection instead). A failure
		// after a keepalive committed HTTP 200 is a mid-stream error to the client.
		if keepaliveCommitted {
			s.recordRequestOutcome(d.model, kvBackend, orClassMidStream)
		} else {
			s.recordRequestOutcome(d.model, kvBackend, classifyOutcomeByCode(statusCode))
		}
		if statusCode == http.StatusTooManyRequests || statusCode == http.StatusServiceUnavailable {
			retryAfter := s.estimateRetryAfter(d.model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			s.recordRejection(d.exhaustedRejectionInfo(reason, statusCode, retryAfter*1000))
		} else {
			s.recordRejection(d.rejectionInfo("dispatch", reason, statusCode, 0))
		}
		if keepaliveCommitted {
			// HTTP 200 was already sent by a prefill keepalive; the status code is
			// frozen, so surface the terminal failure in-band. Responses streams use
			// a different error shape (event: error, no [DONE]) than chat completions.
			//
			// A latched terminal client error with a curated message (today: only
			// the jinja_* template-render stop, which latches
			// terminalClientErrorMessage) surfaces the same invalid_request_error /
			// model_capability body the status-coded writer below returns — NOT a
			// provider_error wrapping d.lastErr, which would leak the provider's
			// raw template backtrace mid-stream. Non-jinja terminals (plain 4xx
			// latches leave the message empty) keep the exact legacy in-band
			// shapes below.
			if d.terminalClientError && d.terminalClientErrorMessage != "" {
				errorCode := "model_capability"
				if d.terminalClientErrorReason == "payload_too_large" {
					errorCode = "payload_too_large"
				}
				if d.isResponsesAPI {
					writeResponsesSSEErrorEvent(w, "invalid_request_error", d.terminalClientErrorMessage)
				} else {
					writeSSEErrorEvent(w, errorResponse(
						"invalid_request_error", d.terminalClientErrorMessage, withCode(errorCode)))
				}
				return
			}
			rateLimited := statusCode == http.StatusTooManyRequests
			capMsg := fmt.Sprintf("all providers at capacity after %d attempt(s): %s", d.attempt+1, d.lastErr)
			errMsg := fmt.Sprintf("inference failed after %d attempt(s): %s", d.attempt+1, d.lastErr)
			if d.isResponsesAPI {
				if rateLimited {
					writeResponsesSSEErrorEvent(w, "rate_limit_exceeded", capMsg)
				} else {
					writeResponsesSSEErrorEvent(w, "provider_error", errMsg)
				}
			} else if rateLimited {
				writeSSEErrorEvent(w, errorResponse("rate_limit_exceeded", capMsg, withCode("rate_limit_exceeded")))
			} else {
				writeSSEErrorEvent(w, errorResponse("provider_error", errMsg))
			}
			return
		}
		if statusCode == http.StatusTooManyRequests {
			writeJSON(w, statusCode, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers at capacity after %d attempt(s): %s", d.attempt+1, d.lastErr),
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
				writeJSON(w, statusCode, errorResponse("invalid_request_error", d.lastErr))
			}
		} else {
			writeJSON(w, statusCode, errorResponse("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", d.attempt+1, d.lastErr)))
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
		s.recordRequestOutcome(d.model, d.kvBackendAttribution(), orClassSuccess)
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

	// Stop any prefill keepalive FIRST, before touching the response-header map
	// below: the keepalive goroutine writes headers via writeSSEResponseHeader, so
	// taking over here guarantees this goroutine is the sole writer (no concurrent
	// map write). headerWritten reports whether a keepalive already committed the
	// SSE 200, in which case the streaming writer skips re-writing it.
	headerWritten := d.keepalive.takeOver()

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
		s.registry.RecordLatency(provider.ID, sample)
	}

	// Write provider attestation headers now that we're committed.
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	provider.Mu().Unlock()

	providerID := provider.ID
	chipName := provider.Hardware.ChipName
	machineModel := provider.Hardware.MachineModel
	if pubKey != "" {
		w.Header().Set("X-Provider-Encrypted", "true")
	}
	if attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(trustLevel))
	w.Header().Set("X-Provider-Id", providerID)
	w.Header().Set("X-Provider-Chip", chipName)
	w.Header().Set("X-Provider-Model", machineModel)
	if attestResult != nil {
		w.Header().Set("X-Provider-Serial", attestResult.SerialNumber)
		if attestResult.SecureEnclaveAvailable {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}
	if mdaVerified {
		w.Header().Set("X-Provider-Mda-Verified", "true")
	}
	// SE public key for attestation receipt verification.
	// Consumers can use this to verify SE signatures on response hashes.
	if attestResult != nil && attestResult.PublicKey != "" {
		w.Header().Set("X-Attestation-Se-Public-Key", attestResult.PublicKey)
		w.Header().Set("X-Attestation-Device-Serial", attestResult.SerialNumber)
	}

	// Latency decomposition header for observability.
	if timing := pr.Timing; timing != nil {
		type timingJSON struct {
			ParseUs   int64 `json:"parse_us"`
			ReserveUs int64 `json:"reserve_us"`
			// MediaFetchUs covers the post-reservation remote media download +
			// inline step (media_resolve.go); omitted for the (typical) request
			// that fetched nothing.
			MediaFetchUs int64 `json:"media_fetch_us,omitempty"`
			RouteUs      int64 `json:"route_us"`
			QueueUs      int64 `json:"queue_us"`
			EncryptUs    int64 `json:"encrypt_us"`
			DispatchUs   int64 `json:"dispatch_us"`
			ProviderUs   int64 `json:"provider_us"`
		}
		tj := timingJSON{}
		if !timing.ParsedAt.IsZero() {
			tj.ParseUs = timing.ParsedAt.Sub(timing.ReceivedAt).Microseconds()
		}
		if !timing.ReservedAt.IsZero() && !timing.ParsedAt.IsZero() {
			tj.ReserveUs = timing.ReservedAt.Sub(timing.ParsedAt).Microseconds()
		}
		// Media fetch (when present) sits between reserve and route; anchor the
		// route segment past it so a download never inflates route_us.
		routeAnchor := timing.ReservedAt
		if !timing.MediaFetchedAt.IsZero() && !timing.ReservedAt.IsZero() {
			tj.MediaFetchUs = timing.MediaFetchedAt.Sub(timing.ReservedAt).Microseconds()
			routeAnchor = timing.MediaFetchedAt
		}
		if !timing.RoutedAt.IsZero() && !routeAnchor.IsZero() {
			tj.RouteUs = timing.RoutedAt.Sub(routeAnchor).Microseconds()
		}
		if !timing.QueuedAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.QueueUs = timing.DispatchedAt.Sub(timing.QueuedAt).Microseconds()
		}
		if !timing.EncryptedAt.IsZero() && !timing.RoutedAt.IsZero() {
			tj.EncryptUs = timing.EncryptedAt.Sub(timing.RoutedAt).Microseconds()
		}
		if !timing.DispatchedAt.IsZero() && !timing.EncryptedAt.IsZero() {
			tj.DispatchUs = timing.DispatchedAt.Sub(timing.EncryptedAt).Microseconds()
		}
		if !timing.FirstChunkAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.ProviderUs = timing.FirstChunkAt.Sub(timing.DispatchedAt).Microseconds()
		}
		if tjJSON, err := json.Marshal(tj); err == nil {
			w.Header().Set("X-Timing", string(tjJSON))
		}
	}

	// On return (disconnect/timeout/completion): free the slot, tell the
	// provider to stop, and preserve billing for a mid-stream disconnect.
	// Park BEFORE RemovePending so a racing provider terminal always finds the
	// record in pending or the holder — never neither (which would drop it and
	// mis-refund). GetPending is nil if a terminal already settled it (normal
	// completion), so nothing is parked then. Both settle paths are
	// FinalizeReservation-guarded, so the park-then-remove overlap can't double-bill.
	defer func() {
		if stale := provider.GetPending(requestID); stale != nil {
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
		s.sendProviderCancel(provider, requestID)
	}()

	// The committed provider's held preamble chunks stream out first, in
	// arrival order, ahead of the content chunk that committed the dispatch.
	firstChunks := d.heldChunks
	if d.firstChunk != "" {
		firstChunks = append(firstChunks, d.firstChunk)
	}
	if d.stream {
		// headerWritten (from the keepalive takeOver at the top) tells the writer
		// to skip re-committing the SSE 200 if a keepalive already did.
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunks, headerWritten)
	} else {
		// Record the OR-uptime outcome from the status the non-streaming writer
		// actually emits: it can still return a 5xx/504 after commit, and a
		// client-gone exit writes no status (0 → not counted, cancelled is excluded).
		// statusWriter (server.go) captures the WriteHeader code and transparently
		// delegates Flush/Hijack/Unwrap, so wrapping preserves the writer's
		// capabilities; zero-valued status starts at 0 (uncounted).
		sw := &statusWriter{ResponseWriter: w}
		s.handleNonStreamingResponseWithFirstChunk(sw, r, pr, firstChunks)
		switch {
		case sw.status == http.StatusOK:
			s.recordRequestOutcome(d.model, d.kvBackendAttribution(), orClassSuccess)
		case sw.status > 0:
			s.recordRequestOutcome(d.model, d.kvBackendAttribution(), classifyOutcomeByCode(sw.status))
		}
	}
}
