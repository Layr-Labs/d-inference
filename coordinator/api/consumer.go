package api

// Consumer-facing API handlers for the Darkbloom coordinator.
//
// This file implements the OpenAI-compatible HTTP endpoints that consumers
// use to send inference requests. The coordinator acts as a trusted routing
// layer between consumers and providers.
//
// Trust model:
//   The coordinator runs in a Confidential VM, providing hardware-encrypted
//   memory. Consumers may additionally sender-seal requests to the
//   coordinator's X25519 key. The coordinator decrypts for routing purposes
//   but never logs prompt content, then re-encrypts each request to the
//   selected provider's X25519 public key before forwarding over the
//   WebSocket. Providers are attested via Secure Enclave challenge-response.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	// inferenceTimeout is the maximum time to wait between chunks (streaming)
	// or for the full response (non-streaming). For streaming, the deadline
	// resets on each received chunk so long-running generations don't time out.
	// 10 minutes allows 32k tokens at ~55 tok/s on slower hardware.
	inferenceTimeout = 600 * time.Second

	// defaultFirstContentDeadlineBase preserves the ordinary coordinator and
	// unit-test budget. Production overrides it to 9s through validated startup
	// configuration; exact model overrides live in modelpolicy and every request
	// adds 1ms per estimated prompt token.
	defaultFirstContentDeadlineBase = 5 * time.Second

	// preambleContentTimeout is the relative cap from the first boilerplate
	// chunk to the first CONTENT chunk. A provider that produced only preamble
	// (role delta / Responses lifecycle) has written ZERO bytes to the client,
	// so a role-then-stall zombie must fail over instead of pinning the request
	// for the full inferenceTimeout. 90s covers the measured pre-content tail
	// (vision prefill is 6-30s). When ReceivedAt is stamped this cap cannot
	// exceed leftover request-absolute first-token budget: AcceptedCh is not a
	// completion token and must not reset that clock.
	preambleContentTimeout = 90 * time.Second

	// chunkBufferSize is the channel buffer size for SSE chunks flowing from
	// the provider to the consumer. A larger buffer prevents dropped chunks
	// when the consumer reads slowly.
	chunkBufferSize = 256

	// maxDispatchAttempts is a SAFETY CEILING on per-request provider failover,
	// not the normal stopping point. A request keeps failing over to fresh
	// healthy providers until one succeeds, OR candidates are exhausted (every
	// failed provider is excluded from re-selection, so dispatchPrimary returns
	// outcomeFailFast on the next attempt once no eligible provider remains), OR
	// the request's deadline/context fires (run() checks r.Context() each
	// attempt). This ceiling only guards against a pathological retry path that
	// fails to exclude a provider (an unbounded hot loop); it is set well above
	// any realistic per-request fault count. Retries never re-queue — only the
	// first attempt may wait for capacity — so failover stays fast, walking the
	// immediately-available healthy providers rather than waiting on busy ones.
	maxDispatchAttempts = 64

	// maxCapacityClassRetries bounds failover specifically for TRANSIENT-capacity
	// rejections (this provider's live KV budget, a full queue, an update drain).
	// Such a shortage MAY clear on another provider, so we fail over — but only a
	// few times, so a fleet-wide transient (or an oversized request the determinism
	// check didn't tag) cannot walk all maxDispatchAttempts providers and 503 each
	// (the prod storm: median 22, max 63 attempts, ~8.7 min, 0% eventual success).
	// A DETERMINISTIC-context rejection (prompt > model context, identical on every
	// provider) stops on the FIRST attempt regardless — see classifyRejection.
	maxCapacityClassRetries = 3

	// maxFirstChunkTimeoutRetries bounds failover for coordinator-synthesized
	// first-chunk TIMEOUTS (the untyped 504 the exhausted ladder reclassifies
	// to a retryable 429 with reason "first_chunk_timeout"). Unlike capacity
	// rejections these carried NO cap: every retry re-ran a full fleet
	// reservation scan (~1,260 providers, registry.ReserveProviderEx), and in
	// the 2026-09-01 congestion collapse retry-amplified inbound (~100 req/s
	// of retryable 429 traffic from OpenRouter) times per-request fleet scans
	// saturated every coordinator CPU — attempt-0 route p50 went 40ms → 4.6s,
	// success ~40%, 429s were delivered after 11s, inbound ~6k/min vs served
	// ~550/min. The request-absolute first-content budget already bounds WALL
	// time per request; this bounds CPU: after this many timed-out attempts
	// (each on a distinct provider — a timed-out provider is excluded from
	// re-selection) the ladder exhausts immediately into the existing
	// synthetic-timeout → 429 reclassification (classifyExhaustedStatus).
	maxFirstChunkTimeoutRetries = 3

	// speculativeTimerRatio is the fraction of the TTFT deadline at which
	// the coordinator launches a speculative backup dispatch. The primary
	// provider gets this fraction of the deadline before the backup is
	// started, and then both race until one produces the first chunk.
	speculativeTimerRatio = 0.5

	// maxHeldBoilerplate bounds how many pre-content boilerplate chunks the
	// dispatch loop holds per provider before committing anyway. Real
	// preambles are one chunk (chat role delta) or two (Responses
	// created/in_progress), so the cap exists only to stop a misbehaving
	// provider from growing the held buffer for the whole inference window.
	// Excess boilerplate is dropped while the first-content clock continues;
	// it must never be mistaken for content and commit a bad provider.
	maxHeldBoilerplate = 8

	// cancelWriteTimeout bounds how long a cancel write to the provider can
	// block. Using context.Background() unbounded here risks hanging the HTTP
	// handler goroutine when a WebSocket is half-dead.
	cancelWriteTimeout = 2 * time.Second
)

// FirstContentDeadline returns this server's request-absolute first-content
// budget for a concrete model. The ordinary base is instance-owned so
// production-like E2E servers can use the production value without mutating
// concurrent unit tests. Exact-model overrides and the fixed 1ms/token slope
// are centralized in modelpolicy.
func (s *Server) FirstContentDeadline(model string, estimatedPromptTokens int) time.Duration {
	base := s.firstContentDeadlineBase
	if base <= 0 {
		base = defaultFirstContentDeadlineBase
	}
	return modelpolicy.CoordinatorFirstContentDeadline(model, estimatedPromptTokens, base)
}

// shedIfModelRejected answers a public/prefer-owner request with 429 +
// Retry-After when its requested alias or resolved build is in the operator
// reject set (EIGENINFERENCE_REJECT_MODELS). This is a deterministic
// per-model circuit breaker: it takes an unhealthy model out of rotation before
// rate-limit, reservation, or routing work, so aggregators see rate limiting
// rather than dropped/cancelled streams. Exclusive self-route bypasses the shed
// because it never falls back to the public fleet.
func (s *Server) shedIfModelRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, policy selfRoutePolicy, publicModel, model string, stream bool, estimatedPromptTokens, requestedMaxTokens int, requiresVision, hasTools bool) bool {
	if policy.enabled || !s.modelShed(model, publicModel) {
		return false
	}
	retryAfter := s.estimateRetryAfter(model)
	if retryAfter <= 0 {
		retryAfter = 30
	}
	s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_shed"})
	s.recordRejection(rejectionInfo{
		r:                     r,
		stage:                 "model_shed",
		reasonCode:            "model_shed",
		httpStatus:            http.StatusTooManyRequests,
		keyID:                 keyIDFromContext(r.Context()),
		consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
		requestedModel:        publicModel,
		resolvedModel:         model,
		stream:                stream,
		estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens:    requestedMaxTokens,
		requiresVision:        requiresVision,
		hasTools:              hasTools,
		selfRouteOnly:         policy.enabled,
		preferOwner:           policy.prefer,
		retryAfterMs:          retryAfter * 1000,
		params:                rejectionSamplingParams(parsed),
	})
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
		fmt.Sprintf("model %q is temporarily rate-limited — retry after %ds", publicModel, retryAfter),
		withCode("rate_limit_exceeded")))
	return true
}

// sendProviderCancel sends a Cancel message for the given request to the
// provider with a bounded timeout so a half-dead WebSocket doesn't hang the
// caller. It reports whether the frame was handed to the writer. Failures are
// logged at debug level because a disconnect race is the expected case — the
// provider may already be gone — but every one is metered
// (inference.cancel_send_failed{reason}) since a dropped cancel is the only
// silent-loss path on the coordinator side of cancel delivery.
//
// This is the raw primitive. Abandon paths that may leave the provider
// generating go through sendAbandonCancel / cancelDispatch so the cancel is
// recorded for terminal correlation and zombie re-sends.
func (s *Server) sendProviderCancel(provider *registry.Provider, requestID string) bool {
	if provider == nil || provider.Conn == nil {
		return false
	}
	cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: requestID}
	cancelData, err := json.Marshal(cancelMsg)
	if err != nil {
		s.logger.Error("failed to marshal cancel message", "request_id", requestID, "error", err)
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), cancelWriteTimeout)
	defer cancel()
	if err := provider.EnqueueText(ctx, cancelData); err != nil {
		s.ddIncr(metricCancelSendFailed, []string{"reason:" + cancelSendFailureReason(err)})
		s.logger.Debug("failed to send cancel (provider may have disconnected)",
			"request_id", requestID, "error", err)
		return false
	}
	return true
}

func writeProviderInferenceRequestDeferred(
	ctx context.Context,
	provider *registry.Provider,
	builder registry.TextFrameBuilder,
	onHandoff registry.TextFrameHandoff,
) (registry.TextFrameWriteMetadata, error) {
	if provider == nil || provider.Conn == nil {
		return registry.TextFrameWriteMetadata{}, errors.New("provider websocket is not connected")
	}
	return provider.WriteTextDeferred(ctx, builder, onHandoff)
}

// cancelDispatch abandons a dispatch attempt that may still be generating
// (hedge loser, client gone before content): removes the pending request,
// marks the provider idle, sends a cancel over WebSocket so the provider stops,
// and refunds this attempt's provider-specific reservation top-up. cause is
// the bounded cancel cause recorded for terminal correlation.
//
// The cancel is sent only when THIS call removed a live pending record and no
// clean terminal has been ingressed for it. A missing record means a provider
// terminal already claimed the attempt (handleInferenceError removes pending
// before publishing on ErrorCh); a completion parked on the speculative
// empty-completion decision leaves the record but marks completion ingress.
// In both cases nothing is running provider-side, and cancelling would only
// cost the provider a no-op frame per request. Attempts whose terminal was
// observed by the caller use cancelDispatchAfterTerminal instead.
//
// The top-up refund only runs if THIS call actually removed the pending request
// (RemovePending returned non-nil). If settlement (handleComplete) already
// claimed it via its own RemovePending, we must not also refund — that would
// double-credit the consumer.
func (s *Server) cancelDispatch(provider *registry.Provider, pr *registry.PendingRequest, cause string) {
	if provider == nil || pr == nil {
		return
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	now := time.Now()
	// Record before RemovePending: a terminal racing this cleanup looks the
	// id up only after its own RemovePending returns nil, and must find the
	// entry rather than log the terminal as unknown.
	created, expired := s.zombieCanceller.record(pr.RequestID, pr.Model, cause, now)
	s.emitExpiredCancelEntries(expired)
	removed := provider.RemovePending(pr.RequestID)
	s.registry.SetProviderIdle(provider.ID)
	if removed != nil && !pr.HasCompletionIngress() {
		pr.Profile.Mark(registry.StampCancelSent)
		s.sendRecordedCancel(provider, pr.RequestID, pr.Model, cause)
	} else if created {
		s.zombieCanceller.forget(pr.RequestID)
	}
	if removed != nil {
		s.refundProviderExtra(pr)
	}
}

// cancelDispatchAfterTerminal is cancelDispatch for an attempt whose provider
// terminal the caller has already observed (ErrorCh value / ChunkCh closed).
// The terminal handler removed the pending record before publishing it, so
// nothing is running provider-side and no cancel frame is sent — only the
// speculative arbitration, idle transition and top-up refund remain.
func (s *Server) cancelDispatchAfterTerminal(provider *registry.Provider, pr *registry.PendingRequest) {
	if provider == nil || pr == nil {
		return
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	removed := provider.RemovePending(pr.RequestID)
	s.registry.SetProviderIdle(provider.ID)
	if removed != nil {
		s.refundProviderExtra(pr)
	}
}

// cancelDispatchForFirstContentTimeout atomically arbitrates timeout cleanup
// against provider ingress. false means an on-time event or another terminal
// already owns the request, so the wait loop must keep draining its channels.
func (s *Server) cancelDispatchForFirstContentTimeout(
	provider *registry.Provider,
	pr *registry.PendingRequest,
) bool {
	if provider == nil || pr == nil {
		return false
	}
	now := time.Now()
	created, expired := s.zombieCanceller.record(pr.RequestID, pr.Model, cancelCauseFirstChunkTimeout, now)
	s.emitExpiredCancelEntries(expired)
	removed, deferred := provider.RemovePendingForFirstContentTimeout(pr.RequestID)
	if deferred || removed == nil {
		if created {
			s.zombieCanceller.forget(pr.RequestID)
		}
		return false
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	s.registry.SetProviderIdle(provider.ID)
	pr.Profile.Mark(registry.StampCancelSent)
	s.sendRecordedCancel(provider, pr.RequestID, pr.Model, cancelCauseFirstChunkTimeout)
	s.refundProviderExtra(pr)
	return true
}

// refundProviderExtra refunds the provider-specific surcharge charged on top of
// the shared base reservation when an attempt is abandoned. It is idempotent:
// after refunding it resets ReservedMicroUSD to the base so a second call (or a
// later settlement) cannot double-refund. The shared base is never refunded
// here — that is handled once by refundReservation (full failure) or by the
// winning attempt's settlement.
func (s *Server) refundProviderExtra(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	extra := pr.ReservedMicroUSD - pr.BaseReservedMicroUSD
	if extra <= 0 {
		return
	}
	_ = s.store.Credit(pr.ConsumerKey, extra, store.LedgerRefund, "reservation_extra_refund:"+pr.RequestID)
	pr.ReservedMicroUSD = pr.BaseReservedMicroUSD
	s.ddIncr("billing.reservation_extra_refunds", []string{"model:" + pr.Model})
}

// writeGenericProviderError writes the terminal HTTP body for a provider error
// on paths WITHOUT a failover ladder or in-band SSE error framing: the generic
// inference handlers (/v1/messages, /v1/completions) and the non-streaming
// chat response assembly. Deterministic non-provider-fault reasons surface the
// SAME curated bodies as the chat dispatch ladder — a jinja_* template-render
// failure becomes the 422 model_capability invalid_request_error (the raw
// template backtrace never reaches a client), gated by the ladder's
// EIGENINFERENCE_JINJA_TERMINAL_REJECT kill switch; tool_noncompliance keeps
// its provider-typed 422 message (already curated and content-free) but in the
// invalid_request_error/model_capability envelope instead of provider_error.
// Every other error is mapped from the closed failure_code vocabulary. Raw
// provider prose is never passed through.
func (s *Server) writeGenericProviderError(w http.ResponseWriter, errMsg protocol.InferenceErrorMessage) {
	errMsg = normalizeInferenceErrorForInternalUse(errMsg)
	if jinjaTerminalRejectEnabled() && isJinjaTemplateErrorReason(errMsg.ErrorReason) {
		writeJSON(w, http.StatusUnprocessableEntity,
			errorResponse("invalid_request_error", jinjaTerminalRejectMessage, withCode("model_capability")))
		return
	}
	if normalizeInferenceErrorReason(errMsg.ErrorReason) == errorReasonToolNoncompliance {
		writeJSON(w, http.StatusUnprocessableEntity,
			errorResponse("invalid_request_error", clientSafeInferenceErrorMessage(errMsg), withCode("model_capability")))
		return
	}
	statusCode := errMsg.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusBadGateway
	}
	writeJSON(w, statusCode, errorResponse("provider_error", clientSafeInferenceErrorMessage(errMsg)))
}

// noteInferenceError feeds the circuit breakers for a provider-side error
// received on a pending request's ErrorCh (any phase, pre- or post-commit):
//   - the shape-keyed inference-error breaker (counts only sickness-shaped
//     500/502/504 for the (provider, model, shape) triple),
//   - the per-provider node-health breaker, which also counts fault-shaped
//     503s (errStr classifies capacity-503 vs fault-503),
//   - the stable-identity ejection breaker (survives reconnect churn), and
//   - the capacity-reject cooldown (the ONLY consumer of capacity-class
//     rejections, which every breaker above deliberately ignores).
//
// It emits the cool-down metric on the inference-error transition and the
// provider_breaker_open metric on the node-health transition into quarantine.
// errStr is the provider's error message and errReason its structured
// InferenceErrorMessage.ErrorReason ("" for synthetic timeouts and legacy
// providers) — the reason feeds the gray-box request-shape classification the
// same way the dispatch failover trusts it (classifyRejection P1).
// terminalCause is the provider's typed InferenceErrorMessage.TerminalCause
// ("" for synthetic terminals and legacy providers): a typed NEUTRAL cause
// (safety_deadline / backpressure_timeout / cancelled — platform policy or
// consumer behavior) feeds NOTHING here, strike or clear; a typed CAPACITY
// cause (admission_timeout — healthy but busy) feeds only the black-hole
// capacity cooldown. Absent/engine_error/unknown causes keep the legacy
// status/string funnels bit-for-bit (see api/terminal_cause.go).
func (s *Server) noteInferenceError(providerID string, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, causes ...protocol.CoordinatorInferenceErrorCause) {
	if providerID == "" || pr == nil {
		return
	}
	// Structured health-neutral outcomes (isProviderHealthNeutralErrorReason:
	// jinja_* template-render failures, tool_noncompliance, and the
	// request-clock-specific deadline_unreachable refusal) never feed provider
	// health or capacity trackers. Gating HERE (the single breaker chokepoint)
	// mirrors the dispatch-funnel gate
	// (dispatchState.noteProviderError) and the reputation exemption
	// (handleInferenceError), and closes the generic-inference path
	// (/v1/messages, /v1/completions), which calls noteInferenceError directly on
	// pre-commit provider errors. Capacity-class rejections never carry these
	// reasons except deadline_unreachable, whose exclusion is intentional.
	if isProviderHealthNeutralErrorReason(errReason) {
		return
	}
	// Typed drain refusal (R2, registry/drain_state.go): the provider is
	// restarting, not sick and not dishonest about capacity. It feeds NO
	// breaker and NO gray-box capacity state (no cooldown strike, no rate
	// derate, no budget clamp). Ingress marks draining before releasing the
	// pending slot, so its queue drain already skips this provider. Do not
	// repeat that mutation here: an idle/serving heartbeat may have cleared
	// the mark while this consumer was waiting to process its error channel.
	if isDrainingErrorReason(errReason) {
		return
	}
	// Typed terminal-cause gate (the deadline-incident fix): the provider told
	// us WHY the attempt died, so the status/string heuristics below must not
	// misread a platform-policy terminal as sickness. Neutral causes touch no
	// tracker at all — strictly neutral, never a success/clear either.
	// admission_timeout records exactly one capacity-signal strike (the
	// black-hole cooldown, whose zero-interleaved-accepts discriminator keeps
	// serving boxes safe) and skips every fault breaker. All other causes —
	// absent (legacy/synthetic), engine_error, the fault causes
	// (prefill_stall / decode_stall / watchdog), and unknown drift values —
	// fall through to the unchanged legacy funnels.
	switch class, _ := classifyTerminalCause(terminalCause); class {
	case causeClassNeutral:
		return
	case causeClassCapacity:
		if s.registry.RecordCapacityRejectBusy(providerID, pr.Model) {
			s.ddIncr(metricCapacityCooldownTripped, []string{"provider_id:" + providerID, "model:" + pr.Model})
			s.logger.Warn("capacity-reject cooldown tripped: provider+model admission-timing-out with zero interleaved accepts — routing will skip the pair until the cooldown expires",
				"provider_id", providerID,
				"model", pr.Model,
				"status_code", statusCode,
				"terminal_cause", terminalCause,
			)
		}
		return
	}
	// Late disconnect-flush strike (registry/version_reset.go): the session this
	// 502 was flushed from was dropped at or before its identity's version-
	// changed reset, so the reset already accounted for it. The flush is
	// recorded HERE, by the request goroutine, not by Disconnect — and
	// registration evicts a same-serial predecessor and stores the new version
	// on one goroutine, ahead of these consumers — so without the check the
	// new binary would be quarantined for the old one's death.
	if s.registry.IsSupersededDisconnectFlush(providerID, statusCode, causes...) {
		return
	}
	if s.registry.RecordInferenceError(providerID, pr.Model, statusCode, pr.Traits.CooldownShape(), causes...) {
		s.ddIncr("routing.cooldown_entered", []string{"model:" + pr.Model})
	}
	// Feed EVERY provider terminal into the per-provider node-health breaker (not
	// just the shape-keyed 5xx the inference-error breaker counts) so a node
	// fault-503ing ~all of its requests gets quarantined fleet-wide. errStr lets
	// the breaker tell a capacity-503 (ignored) from a fault-503 (counted). Both
	// breakers coexist.
	if opened, _ := s.registry.RecordProviderOutcome(providerID, false, statusCode, errStr, causes...); opened {
		s.ddIncr("routing.provider_breaker_open", []string{"model:" + pr.Model})
	}
	// Feed the STABLE-IDENTITY ejection breaker too (survives reconnect churn, so a
	// zombie that fault-loops while constantly disconnecting still accumulates).
	if ejected, _ := s.registry.RecordProviderSessionServeOutcome(providerID, false, statusCode, errStr, causes...); ejected {
		s.ddIncr("routing.provider_ejected", []string{"model:" + pr.Model})
	}
	// Feed the capacity-reject cooldown. Capacity-class rejections are
	// DELIBERATELY invisible to reputation and to ALL the breakers above (a
	// busy box must never be punished for shedding) — which turns a box that
	// capacity-rejects EVERYTHING into a routing black hole: its idle-looking
	// heartbeats keep winning the cost scheduler while every dispatch bounces
	// (2026-07 incident: 7 boxes, ~9k "token_budget_exhausted" rejections in
	// 30 min, zero successes). Strikes accumulate per (provider, model); any
	// accept (first content chunk or clean completion) resets the streak, so
	// transient fullness on a serving box can never trip. Gated to 429/404/5xx
	// so a client-shape 4xx that happens to carry a capacity-looking string
	// never strikes; explicit context-overflow rejections are excluded by
	// isCapacityRejectStrike (they indict the request, not the provider).
	//
	// 404 is included WITH CARE for the cold "model not loaded" miss: a lazy
	// load on first touch makes a 404-then-load-then-serve sequence NORMAL
	// lifecycle, so the zero-interleaved-accepts discriminator remains the
	// safety — the first accept after the load clears the streak, and only a
	// box that 404s FOREVER (never loads, zero accepts) trips. A 404 whose
	// message is not capacity-class (e.g. "model not found" for an unknown
	// model id — a request-shape error) never strikes, because
	// isCapacityRejectStrike only matches the capacity vocabulary
	// ("not loaded" / "no model loaded").
	if (statusCode == http.StatusTooManyRequests || statusCode == http.StatusNotFound ||
		statusCode >= http.StatusInternalServerError) &&
		isCapacityRejectStrike(errStr) {
		// A cold "model not loaded" miss is benign warm-up lifecycle, not
		// capacity dishonesty. It still feeds the black-hole cooldown (a box
		// that 404s forever with zero accepts is a black hole), but it must NOT
		// derate the pair's gray-box capacity-503 RATE (capacity_rate.go) — that
		// window has no accept-reset, so counting a healthy box's normal reloads
		// would penalize it. A "batch token budget" reject that classifyRejection
		// proves REQUEST-deterministic (provider budget not below the model
		// context ⇒ the binding term was the fleet-wide context) indicts the
		// request, not the provider: it counts a cooldown strike only — arming
		// the one-shot clamp or the no-reset rate window off a single oversized
		// prompt would gate/derate a healthy pair. Genuine capacity/token-budget
		// 503s feed everything.
		var tripped bool
		switch {
		case isColdModelMissRejection(errStr):
			tripped = s.registry.RecordCapacityRejectLifecycle(providerID, pr.Model)
		case s.isRequestShapeBatchBudgetReject(providerID, pr.Model, errStr, errReason):
			tripped = s.registry.RecordCapacityRejectRequestShape(providerID, pr.Model)
		default:
			tripped = s.registry.RecordCapacityReject(providerID, pr.Model)
		}
		if tripped {
			s.ddIncr(metricCapacityCooldownTripped, []string{"provider_id:" + providerID, "model:" + pr.Model})
			s.logger.Warn("capacity-reject cooldown tripped: provider+model capacity-rejecting with zero interleaved accepts — routing will skip the pair until the cooldown expires",
				"provider_id", providerID,
				"model", pr.Model,
				"status_code", statusCode,
			)
		}
	}
}

// metricCapacityCooldownTripped counts transitions of a (provider, model) pair
// into the capacity-reject routing cooldown (registry/capacity_cooldown.go),
// tagged provider_id + model. Distinct from routing.cooldown_entered (the 5xx
// inference-error breaker) and routing.provider_breaker_open (node health) so
// black-hole trips are independently alertable.
const metricCapacityCooldownTripped = "routing.capacity_cooldown_tripped"

// isRequestShapeBatchBudgetReject reports whether a capacity-class rejection
// is PROVEN request-deterministic by classifyRejection: a "batch token budget"
// reject from a provider whose reported token budget is not below the model's
// context window (the admission cap min(context, budget) was the CONTEXT — the
// prompt is too big fleet-wide), or an explicit request_exceeds_context
// structured reason. Such a reject must arm neither the one-shot budget clamp
// nor the no-reset capacity-503 rate window
// (RecordCapacityRejectRequestShape). When the reported budget IS below the
// context, the binding term may have been this node's memory-pressured KV
// budget — a genuine provider-specific capacity signal — and the reject feeds
// the full gray-box state (same discrimination the dispatch failover uses:
// classifyRejection in inference_failure_class.go, DAR-347).
//
// Inputs mirror the dispatch path exactly: the structured errReason
// (InferenceErrorMessage.ErrorReason — a provider that says
// request_exceeds_node_budget / capacity_busy is TRUSTED over the stale
// heartbeat-budget heuristic, so a stale snapshot that still reads >= context
// cannot misroute a genuine node-capacity failure away from the gray-box
// trackers), providerBudget from the provider's last heartbeat
// (ReportedTokenBudgetMaxForModel), and modelContext from the model registry
// record. Called only inside the isCapacityRejectStrike branch, so explicit
// context-overflow STRINGS never reach it (they never strike at all). The
// cheap gate keeps the two lookups off every other rejection.
func (s *Server) isRequestShapeBatchBudgetReject(providerID, model, errStr, errReason string) bool {
	e := strings.ToLower(strings.TrimSpace(errStr))
	e = strings.ReplaceAll(e, "’", "'")
	reason := strings.ToLower(strings.TrimSpace(errReason))
	if !strings.Contains(e, "batch token budget") && reason != "request_exceeds_context" {
		return false
	}
	var providerBudget int64
	if p := s.registry.GetProvider(providerID); p != nil {
		providerBudget = p.ReportedTokenBudgetMaxForModel(model)
	}
	modelContext := 0
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil && rec != nil {
		modelContext = rec.MaxContextLength
	}
	// No typed CapacityRejectionReason threads into the strike funnel
	// (noteInferenceError carries only the string vocabulary), so this stays
	// the legacy string+heartbeat heuristic — enriched typed reasons already
	// reach it mapped onto error_reason by the sanitizer.
	return classifyRejection(errReason, errStr, providerBudget, modelContext, "") == rejectionDeterministicUnservable
}

// noteInferenceSuccess clears the inference-error strike state for the serving
// provider-model pair on a clean completion (streaming relay ended without a
// provider error; non-streaming response assembled OK).
func (s *Server) noteInferenceSuccess(pr *registry.PendingRequest) {
	if pr == nil || pr.ProviderID == "" {
		return
	}
	s.registry.RecordInferenceSuccess(pr.ProviderID, pr.Model, pr.Traits.CooldownShape())
	// A clean completion is an ACCEPT for the capacity-reject cooldown: clear
	// the pair's reject streak, any active capacity cooldown, and the re-trip
	// backoff. Belt-and-braces with the commit-time accept (commitFirstContent)
	// and the only accept signal on paths that never stream content. For the
	// capacity-503 RATE window (capacity_rate.go) one served request must
	// count exactly ONE outcome, so this completion-time accept re-offers the
	// outcome only when the commit-time accept did not actually RECORD one
	// (RateOutcomeCountedSafe — stamped from RecordCapacityAccept's return at
	// every commit site). With rate tracking enabled, commit-time accepts are
	// retained even before the first reject; paths that never commit content
	// record their sole outcome here instead.
	s.registry.RecordCapacityAcceptOutcome(pr.ProviderID, pr.Model, !pr.RateOutcomeCountedSafe())
	// A clean completion proves the node is healthy — close its node-health
	// breaker (and reset the exponential backoff) if it had tripped.
	if _, closed := s.registry.RecordProviderOutcome(pr.ProviderID, true, 200, ""); closed {
		s.ddIncr("routing.provider_breaker_closed", []string{"model:" + pr.Model})
	}
	// A clean completion is a success for the stable-identity ejection breaker too
	// — closes it (half-open recovery) if this identity had been ejected.
	if sid := s.registry.GetProviderStableIdentity(pr.ProviderID); sid != "" {
		if _, recovered := s.registry.RecordProviderServeOutcome(sid, true, 200, ""); recovered {
			s.ddIncr("routing.provider_ejection_recovered", []string{"model:" + pr.Model})
		}
	}
}

// noteDispatchProviderError records a provider error received while the
// dispatch loop had NOT yet committed to that provider: it feeds the
// inference-error breaker, refunds the failed attempt's provider-specific
// reservation top-up, and, when boilerplate chunks from that provider were
// being held (deferred commit), discards them and emits the pre-content
// failover counter — the invisible-retry signal that replaces what used to be
// an in-band SSE error after a premature commit. Returns true when held
// chunks were discarded so callers skip their generic retry counter.
//
// The refund lives here because both ErrorCh senders (handleInferenceError and
// registry.Disconnect's pending flush) remove the pending request BEFORE
// pushing the error, so the arm's cancelDispatch sees RemovePending()==nil and
// skips its own refund — without this the custom-price surcharge reserved by
// reserveAdditionalForProvider would be stranded for the failed attempt.
// refundProviderExtra is idempotent (it resets ReservedMicroUSD to the base),
// so arms where cancelDispatch did refund are safe, and a failed pre-commit
// attempt never reaches settlement (its channels are closed and it is neither
// pending nor parked), so this can never double-credit against a settle.
func (s *Server) noteDispatchProviderError(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string, causes ...protocol.CoordinatorInferenceErrorCause) (discardedHeld bool) {
	if provider != nil {
		s.noteInferenceError(provider.ID, pr, statusCode, errStr, errReason, terminalCause, causes...)
	}
	s.refundProviderExtra(pr)
	if held == nil || len(*held) == 0 {
		return false
	}
	*held = nil
	s.ddIncr("inference.dispatches", []string{"status:retry_precontent"})
	return true
}

// failedProviderVersion reads a provider's reported binary version under its
// lock (mirroring the policy.prefer owner reads). Captured when an attempt
// fails so the next attempt's Traits.AvoidVersion can steer the retry to a
// different build — a deterministic per-version bug must not burn every retry
// on identical binaries.
func failedProviderVersion(p *registry.Provider) string {
	if p == nil {
		return ""
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Version
}

// errModelTooLarge is the dispatch error returned when providers serve the
// requested model but none of them has enough total memory to ever load it.
// Distinct from "no provider available" so the caller rejects fast instead of
// queuing for 120s — queueing can't help a model that will never fit.
const errModelTooLarge = "model too large for any available provider"

// errTTFTTooSlow is the dispatch error returned when providers are available
// but all of them exceed the per-request TTFT ceiling. Distinct from
// "no provider available" so the caller returns a retryable 429 instead of
// queueing for a provider that would miss the OpenRouter SLA target.
const errTTFTTooSlow = "all available providers exceed the TTFT target"

// errFirstContentDeadlineExpired is returned when the request-absolute
// first-content clock runs out before an inference_request reaches the provider
// wire. No provider work was started, so callers surface a deadline 429 without
// charging provider health.
const errFirstContentDeadlineExpired = "first-content deadline expired before provider dispatch"

// errRoutingScanSaturated is returned when no provider-selection scan slot
// (Server.routingScanSem) freed up within the request's remaining
// first-content budget: the coordinator itself is the bottleneck (the
// 2026-09-01 congestion collapse). No provider was scanned or contacted, so
// callers shed ONE capacity-shaped retryable 429 — never a 5xx, never more
// scans.
const errRoutingScanSaturated = "routing scan capacity saturated — coordinator busy"

// errClientGoneBeforeScan is returned when the caller's context fired while
// the dispatch goroutine was parked for a provider-selection scan slot. No
// provider was scanned or contacted; the dispatch loop takes its ordinary
// client-gone terminal (cancelled route outcome, refund, no response body) —
// never the routing_saturated 429 or a rejection-ledger row.
const errClientGoneBeforeScan = "client disconnected before provider selection"

// attempt0RouteAnchor returns the instant the attempt-0 route-latency EWMA
// sample is measured from — the SAME anchor applyTimingDecomposition uses for
// route_ms (MediaFetchedAt when a remote-media fetch happened, else
// ReservedAt) — so download or parse time can never fake routing distress.
// Zero when the request never stamped a reservation (bare test fixtures):
// the caller then records no sample.
func attempt0RouteAnchor(t *registry.RequestTiming) time.Time {
	if t == nil {
		return time.Time{}
	}
	if !t.MediaFetchedAt.IsZero() {
		return t.MediaFetchedAt
	}
	return t.ReservedAt
}

// consumerModel returns the model name to echo back to the consumer: the public
// alias they requested when set, otherwise the concrete build id (raw-id
// requests and any internal caller that didn't populate PublicModel).
func consumerModel(pr *registry.PendingRequest) string {
	if pr.PublicModel != "" {
		return pr.PublicModel
	}
	return pr.Model
}

// rewriteChunkModel replaces the concrete build id in a streamed SSE chunk's
// "model" field with the public alias the consumer requested, so streaming
// responses never expose the underlying build/quant. No-op when the request
// used a raw build id (PublicModel == Model) or no alias was set. Uses a
// precise key+value string replace (both compact and spaced JSON forms) to
// avoid parsing every chunk on the hot path.
func rewriteChunkModel(chunk string, pr *registry.PendingRequest) string {
	if pr.PublicModel == "" || pr.PublicModel == pr.Model {
		return chunk
	}
	chunk = strings.ReplaceAll(chunk, `"model":"`+pr.Model+`"`, `"model":"`+pr.PublicModel+`"`)
	chunk = strings.ReplaceAll(chunk, `"model": "`+pr.Model+`"`, `"model": "`+pr.PublicModel+`"`)
	return chunk
}

// resolveRequestedModel maps the consumer-requested model — which may be a
// public alias like "gemma-4-26b" — to the concrete build id used for routing,
// billing, and serving, returning the public name to echo back to the consumer.
// When the request used an alias it rewrites parsed["model"] and returns an
// updated rawBody so the provider receives the concrete build. Raw build ids
// pass through unchanged (publicModel == buildModel). ok=false means the alias
// currently has no usable build; the caller should surface a model_unavailable
// error.
func (s *Server) resolveRequestedModel(
	parsed map[string]any,
	rawBody []byte,
	requested string,
	allowedProviderSerials []string,
	policy selfRoutePolicy,
	traits registry.RequestTraits,
) (buildModel, publicModel string, newRawBody []byte, ok bool) {
	buildID, isAlias, resolved := s.registry.ResolveModelConstrainedWithTraits(
		requested, allowedProviderSerials, policy.ownerAccountID,
		policy.enabled, policy.prefer, traits)
	if !resolved {
		return "", requested, rawBody, false
	}
	if !isAlias {
		return requested, requested, rawBody, true
	}
	parsed["model"] = buildID
	rb, err := marshalForwardBody(parsed)
	if err != nil {
		rb = rawBody
	}
	return buildID, requested, rb, true
}

// aliasFallbackMode selects the failure policy for maybeFallbackAlias.
type aliasFallbackMode int

const (
	// aliasFallbackCapacity routes to Previous whenever it has any free capacity.
	aliasFallbackCapacity aliasFallbackMode = iota
	// aliasFallbackTTFT additionally rejects Previous when its best TTFT estimate
	// would miss the per-request ceiling (ttftThreshold).
	aliasFallbackTTFT
)

// maybeFallbackAlias keeps public aliases available during a desired-build
// saturation event. Alias resolution intentionally prefers Desired when it is
// routable, but if every desired provider is transiently full (aliasFallbackCapacity)
// or too slow to hit the TTFT ceiling (aliasFallbackTTFT) and Previous can serve,
// route this request to Previous instead of returning a fast 429 / slow stream.
// Hard constraints and permanent model-too-large failures are handled by the
// caller and do not use this fallback. The TTFT estimate for Previous is also
// returned so the caller does not need to recompute it. ttftThreshold is the
// request-local deadline pinned before admission and is only consulted in
// aliasFallbackTTFT mode.
func (s *Server) maybeFallbackAlias(parsed map[string]any, mode aliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string) (string, int, int, int, time.Duration, bool, bool) {
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false
	}
	target, ok := s.registry.AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false
	}
	// Previous must be a real, non-shed catalog build before we probe it.
	if s.modelShed(target.Previous, publicModel) || !s.registry.IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false
	}
	// A SINGLE Previous-build probe drives both modes; the mode only decides
	// whether the probe's TTFT estimate also gates the fallback.
	candidates, rejections, tooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(target.Previous, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedProviderSerials...)
	enforceTTFT := mode == aliasFallbackTTFT
	if candidates <= 0 || (enforceTTFT && ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold)) {
		// No fallback. TTFT mode reports the probed Previous build (the caller
		// uses it as the alternate TTFT estimate); capacity mode discards the
		// model, so keep the unchanged current build.
		failModel := currentModel
		if enforceTTFT {
			failModel = target.Previous
		}
		return failModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, false
	}
	parsed["model"] = target.Previous
	return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, true
}

func ttftTooSlow(bestTTFT time.Duration, hasTTFT bool, threshold time.Duration) bool {
	return hasTTFT && bestTTFT > threshold
}

// hardTTFTGateApplies reports whether the scheduler's token-prefill estimate is
// authoritative enough to reject this request before dispatch. Media requests
// run CPU decode plus a separate vision tower before text prefill; neither cost
// exists in estimatedTTFTFromSnapshot, so treating that partial estimate as a
// hard ceiling rejects healthy video/image requests on a number that cannot
// predict their TTFT. They still use the best-available provider and remain
// bounded by the same request-absolute first-content deadline.
func (s *Server) hardTTFTGateApplies(requiresVision bool) bool {
	return s.ttftHardReject && !requiresVision
}

func fasterTTFTEstimate(primaryModel string, primary time.Duration, alternateModel string, alternate time.Duration, alternateOK bool) (string, time.Duration) {
	if alternateOK && alternate < primary {
		return alternateModel, alternate
	}
	return primaryModel, primary
}

func (s *Server) estimateTTFTRetryAfter(model string, bestTTFT, threshold time.Duration) int {
	overage := bestTTFT - threshold
	seconds := int(math.Ceil(overage.Seconds()))
	if base := s.estimateRetryAfter(model); seconds < base {
		seconds = base
	}
	if seconds < 2 {
		seconds = 2
	}
	if seconds > 30 {
		seconds = 30
	}
	return seconds
}

func (s *Server) writeTTFTTooSlow(w http.ResponseWriter, model, publicModel string, bestTTFT, threshold time.Duration) {
	retryAfter := s.estimateTTFTRetryAfter(model, bestTTFT, threshold)
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:ttft_429"})
	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
		ttftTooSlowMessage(publicModel, bestTTFT, threshold, retryAfter),
		withCode("rate_limit_exceeded")))
}

// ttftTooSlowMessage is the single wording for a fleet-wide TTFT rejection.
func ttftTooSlowMessage(publicModel string, bestTTFT, threshold time.Duration, retryAfter int) string {
	return fmt.Sprintf(
		"all providers for model %q are above the %ds TTFT target (best estimate %.1fs); retry after %ds",
		publicModel, int(math.Ceil(threshold.Seconds())), bestTTFT.Seconds(), retryAfter)
}

func (s *Server) triggerWarmPool() {
	if s == nil || s.registry == nil {
		return
	}
	s.registry.RequestWarmPoolTrigger()
}

func (s *Server) recordWarmPoolQueueState(model string) {
	if s == nil || s.registry == nil || s.registry.Queue() == nil {
		return
	}
	depth, oldest := s.registry.Queue().QueueStats(model)
	if depth <= 0 {
		s.registry.RecordWarmPoolQueueCleared(model)
		return
	}
	s.registry.RecordWarmPoolQueueEnqueued(model, depth, oldest)
	s.triggerWarmPool()
}

// ttftMsForRejection converts a pre-flight TTFT estimate to milliseconds for the
// rejection ledger, returning 0 when the pre-flight produced no estimate.
func ttftMsForRejection(bestTTFT time.Duration, hasTTFT bool) float64 {
	if !hasTTFT {
		return 0
	}
	return float64(bestTTFT.Milliseconds())
}

// rejectionSamplingParams captures only the non-content sampling knobs already
// parsed from an inbound request body for the rejection ledger. It never
// includes prompt/message/input content. Returns nil when none are present.
func rejectionSamplingParams(parsed map[string]any) json.RawMessage {
	if parsed == nil {
		return nil
	}
	knobs := make(map[string]any, 4)
	for _, k := range []string{"temperature", "top_p", "presence_penalty", "frequency_penalty"} {
		if v, ok := parsed[k]; ok {
			knobs[k] = v
		}
	}
	if len(knobs) == 0 {
		return nil
	}
	b, err := json.Marshal(knobs)
	if err != nil {
		return nil
	}
	return b
}

type routeDecisionRecorder func(*registry.Provider, *registry.PendingRequest, registry.RoutingDecision)

// dispatchReserver selects and atomically reserves a provider for an
// already-constructed PendingRequest. It is the ONE seam between provider
// SELECTION and the single prepare/encrypt/write funnel in
// dispatchWithReserver: wave-2 callers plug in the retained-plan variants
// (ReserveNextFromPlan / RefreshDispatchPlan) without forking the funnel.
// The returned plan is non-nil only for scan-backed reservers that retain
// alternates.
type dispatchReserver func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan)

// dispatchOneProvider encrypts and sends an inference request to a single
// provider selected by a fresh full scan. It returns the pending request and
// provider on success, or an error string on failure, plus the bounded
// DispatchPlan of provisional alternates retained from the SAME scan (nil
// whenever no provider was reserved) so retries and speculative backups can
// consume retained identities instead of rescanning the fleet (Routing v2
// Phase 3). The excludeProviders set is updated on failure. selfRoutePolicy
// and its resolvers live in self_route.go.
func (s *Server) dispatchOneProvider(
	r *http.Request,
	model string,
	publicModel string,
	rawBody []byte,
	consumerKey string,
	consumerLocation *store.ProviderLocation,
	reservedMicroUSD int64,
	estimatedPromptTokens int,
	requestDeadline time.Duration,
	requestedMaxTokens int,
	tokenAdmission registry.TokenAdmission,
	requiresVision bool,
	traits registry.RequestTraits,
	allowedProviderSerials []string,
	isResponsesAPI bool,
	policy selfRoutePolicy,
	timing *registry.RequestTiming,
	serviceReservation bool,
	cachePlan registry.CachePlan,
	excludeProviders map[string]struct{},
	attempt int,
	rp *registry.RequestProfile,
	backupOf string,
	recordRoute routeDecisionRecorder,
	onDispatched func(),
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	plan *registry.DispatchPlan,
	lastErr string,
	lastErrCode int,
) {
	return s.dispatchWithReserver(
		r, model, publicModel, rawBody, consumerKey, consumerLocation,
		reservedMicroUSD, estimatedPromptTokens, requestDeadline,
		requestedMaxTokens, tokenAdmission, requiresVision, traits,
		allowedProviderSerials, isResponsesAPI, policy, timing,
		serviceReservation, cachePlan, excludeProviders, attempt, rp, backupOf,
		recordRoute, onDispatched,
		true, // ReserveProviderWithPlan is the O(fleet) full scan
		func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
			return s.registry.ReserveProviderWithPlan(model, pr, excludeIDs...)
		},
	)
}

// dispatchWithReserver is the single prepare/encrypt/write funnel behind every
// provider dispatch: pending construction and admission stamps, the pluggable
// reservation, the billing surcharge, E2E encryption, and the
// deadline-bounded provider write, with releaseUnsentDispatch cleanup on every
// failure path. onDispatched (nil-safe) fires inside the write handoff
// callback — the same instant Timing.DispatchedAt is stamped — so
// providerDispatches counts frames that actually reached a provider, never
// loop attempts.
func (s *Server) dispatchWithReserver(
	r *http.Request,
	model string,
	publicModel string,
	rawBody []byte,
	consumerKey string,
	consumerLocation *store.ProviderLocation,
	reservedMicroUSD int64,
	estimatedPromptTokens int,
	requestDeadline time.Duration,
	requestedMaxTokens int,
	tokenAdmission registry.TokenAdmission,
	requiresVision bool,
	traits registry.RequestTraits,
	allowedProviderSerials []string,
	isResponsesAPI bool,
	policy selfRoutePolicy,
	timing *registry.RequestTiming,
	serviceReservation bool,
	cachePlan registry.CachePlan,
	excludeProviders map[string]struct{},
	attempt int,
	rp *registry.RequestProfile,
	backupOf string,
	recordRoute routeDecisionRecorder,
	onDispatched func(),
	fullScan bool,
	reserve dispatchReserver,
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	plan *registry.DispatchPlan,
	lastErr string,
	lastErrCode int,
) {
	receivedAt := timingReceivedAt(timing)
	_, dispatchable := firstContentBudgetMillis(receivedAt, requestDeadline)
	if !dispatchable {
		return nil, nil, decision, nil, errFirstContentDeadlineExpired, http.StatusGatewayTimeout
	}

	requestID := uuid.New().String()
	ap := rp.NewAttempt(requestID, attempt, backupOf)
	ap.Mark(registry.StampAttemptStart)
	// Any failure return closes the attempt as not dispatched (terminal half; the handler half lands in finalizeProfile);
	// a dispatched attempt is left for the provider terminal / relay to close.
	defer func() {
		if provider == nil {
			closeUndispatchedAttempt(ap, lastErr, lastErrCode)
		}
	}()
	pr = &registry.PendingRequest{
		RequestID: requestID,
		Profile:   ap,
		// Attempt is stamped at construction — BEFORE the request is encrypted
		// and sent to the provider — so a fast provider that returns
		// inference_complete immediately is correlated to the right route row.
		// Setting it after the send (on the dispatch goroutine) would race the
		// provider WS reader goroutine's handleComplete read of pr.Attempt.
		Attempt:                attempt,
		Model:                  model,
		PublicModel:            publicModel,
		ConsumerKey:            consumerKey,
		KeyID:                  keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:          keyLimitResetFromContext(r.Context()),
		ConsumerLocation:       consumerLocation,
		IsResponsesAPI:         isResponsesAPI,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequiresVision:         requiresVision,
		Traits:                 traits,
		RequestedMaxTokens:     requestedMaxTokens,
		TokenAdmission:         tokenAdmission,
		CachePlan:              cachePlan,
		ReservedMicroUSD:       reservedMicroUSD,
		BaseReservedMicroUSD:   reservedMicroUSD,
		ServiceReservation:     serviceReservation,
		AllowedProviderSerials: allowedProviderSerials,
		SelfRouteOnly:          policy.enabled,
		PreferOwner:            policy.prefer,
		OwnerAccountID:         policy.ownerAccountID,
		FreeSelfRoute:          policy.enabled,
		MetadataDetails:        metadataDetailsFromRequest(r),
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan registry.ProviderChunk, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
		Timing:                 timing,
	}
	if !receivedAt.IsZero() {
		pr.FirstContentDeadline = receivedAt.Add(requestDeadline)
	}

	// Public inference routes (not self-route / prefer-owner) enforce the
	// OpenRouter TTFT ceiling inside the scheduler. This makes the preflight
	// check authoritative: the router cannot select a provider whose estimated
	// TTFT is above the threshold.
	// Routing v2 (P1 fix): only enforce the TTFT ceiling inside the scheduler when
	// the HARD gate is on. In soft mode (default) MaxTTFTMs stays 0 so the primary
	// dispatch serves the best-available provider instead of re-rejecting an
	// over-threshold request the preflight already chose to soft-serve. (Mirrors
	// queueMaxTTFTMs, which already returns 0 in soft mode.)
	if !policy.enabled && !policy.prefer && s.hardTTFTGateApplies(requiresVision) {
		pr.MaxTTFTMs = float64(requestDeadline.Milliseconds())
	}
	// Refresh immediately before reservation: every retry spends the same
	// absolute clock, so the scheduler must never see the original ceiling.
	if !pr.RefreshFirstContentBudget(time.Now()) {
		return nil, nil, decision, nil, errFirstContentDeadlineExpired, http.StatusGatewayTimeout
	}
	// Routing v2 W2: soft per-request decode floor (0 = off). Applies to all
	// routes; it only ranks providers, never rejects.
	pr.MinDecodeTPS = s.minDecodeTPS

	excludeList := func() []string {
		ids := make([]string, 0, len(excludeProviders))
		for id := range excludeProviders {
			ids = append(ids, id)
		}
		return ids
	}

	// noteSelectionSample feeds the attempt-0 route-latency distress EWMA
	// behind estimateRetryAfter (2026-09-01: route p50 40ms → 4.6s while the
	// empty-queue heuristic kept answering "retry in 2s"). Anchored exactly
	// where applyTimingDecomposition anchors route_ms (MediaFetchedAt when
	// set, else ReservedAt) so a multi-second media download or slow body
	// parse can never masquerade as routing distress. Called on BOTH the
	// successful reservation (at the RoutedAt stamp) and every failed
	// attempt-0 selection (semaphore acquisition timeout, scan that yields no
	// provider): under TOTAL overload no selection ever succeeds, and an
	// EWMA fed only by successes would sit at 0 — keeping Retry-After at the
	// legacy 2s exactly when distress scaling matters most.
	noteSelectionSample := func() {
		if attempt != 0 {
			return
		}
		if anchor := attempt0RouteAnchor(timing); !anchor.IsZero() {
			s.noteAttempt0RouteLatency(time.Since(anchor))
		}
	}

	// Bound concurrent provider-selection scans (2026-09-01 congestion
	// collapse: retry-amplified inbound × a fresh full fleet scan per attempt
	// saturated every coordinator CPU). Only O(fleet) reservers take a slot —
	// the full scan, the plan REFRESH (itself a full re-scan), and the
	// speculative-backup scan. A retained-plan step (ReserveNextFromPlan)
	// revalidates at most the plan's bounded entries, so it bypasses the
	// semaphore: a held slot must never starve the cheap retry path that
	// exists precisely to avoid rescans. The wait is bounded by the request's
	// remaining first-content budget: a goroutine parks cheaply on the channel
	// and either scans as soon as a slot frees or sheds capacity-shaped
	// (errRoutingScanSaturated → one retryable 429) once the budget is gone.
	if fullScan {
		switch s.acquireRoutingScanSlot(
			firstTokenRemainingSince(receivedAt, requestDeadline),
			r.Context().Done(),
		) {
		case scanSlotClientGone:
			// The caller vanished while parked for a slot: this is the
			// ordinary client-gone terminal, never the routing_saturated
			// 429/rejection row (and no distress sample — a vanished caller
			// proves nothing about selection latency).
			return nil, nil, decision, nil, errClientGoneBeforeScan, 0
		case scanSlotTimeout:
			noteSelectionSample()
			return nil, nil, decision, nil, errRoutingScanSaturated, http.StatusTooManyRequests
		}
	}
	provider, decision, plan = reserve(pr, excludeList())
	ap.Mark(registry.StampReserveDone)
	ap.SetDecision(decision)
	if fullScan {
		s.releaseRoutingScanSlot()
	}
	if provider == nil {
		noteSelectionSample()
		// Providers serve this model but none can physically fit it: don't make
		// the caller queue/retry for something that will never load.
		if decision.CandidateCount == 0 && decision.CapacityRejections == 0 && decision.ModelTooLargeRejections > 0 {
			return nil, nil, decision, plan, errModelTooLarge, http.StatusServiceUnavailable
		}
		// Providers are available but all exceed the TTFT ceiling. Fail fast
		// with a retryable 429 rather than queueing or routing to a slow
		// provider.
		if decision.TTFTRejections > 0 {
			return nil, nil, decision, plan, errTTFTTooSlow, http.StatusTooManyRequests
		}
		return nil, nil, decision, plan, "no provider available", http.StatusServiceUnavailable
	}
	pendingCleanup := true
	cleanupPending := func() {
		if pendingCleanup {
			s.releaseUnsentDispatch(provider, pr)
			pendingCleanup = false
		}
	}
	defer cleanupPending()
	if pr.Timing != nil {
		pr.Timing.RoutedAt = time.Now()
	}
	noteSelectionSample()
	if ap != nil {
		ap.ProviderID = provider.ID
		provider.Mu().Lock()
		ap.ProviderVersion = provider.Version
		ap.ChipFamily = provider.Hardware.ChipFamily
		provider.Mu().Unlock()
		ap.KVBackend, _ = provider.SlotKVBackendTags(model)
	}
	if recordRoute != nil {
		recordRoute(provider, pr, decision)
	}

	// A request settles FREE when it's served by a machine the caller owns:
	// exclusive self-route (policy.enabled) always, OR a prefer request whose
	// SELECTED provider is the caller's own machine (settlement refunds it to
	// zero). In that case there is no payout and no reservation to top up — and
	// applying a provider custom price above the platform rate would wrongly 429
	// the free owned route, so skip both the payout warning and the top-up.
	settlesFree := policy.enabled
	if !settlesFree && policy.prefer {
		provider.Mu().Lock()
		settlesFree = policy.ownerAccountID != "" && provider.AccountID == policy.ownerAccountID
		provider.Mu().Unlock()
	}

	if s.billing != nil && !settlesFree && !providerHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}

	// Free (owned) requests are settled at zero cost (handleComplete), so there
	// is no reservation to top up for a provider's custom price.
	if s.billing != nil && !settlesFree {
		_, err := s.reserveAdditionalForProvider(pr, provider)
		if err != nil {
			cleanupPending()
			excludeProviders[provider.ID] = struct{}{}
			if errors.Is(err, store.ErrInsufficientBalance) {
				return nil, nil, decision, plan, "insufficient funds for provider price", http.StatusPaymentRequired
			}
			s.logger.Error("provider reservation failed (DB error)", "provider_id", provider.ID, "error", err)
			return nil, nil, decision, plan, "service temporarily unavailable — please retry", http.StatusServiceUnavailable
		}
	}
	ap.Mark(registry.StampTopupDone)
	// refundExtra credits back the provider-specific surcharge that
	// reserveAdditionalForProvider may have added. The caller's
	// refundReservation only covers the base reservation.
	refundExtra := func() {
		extra := pr.ReservedMicroUSD - reservedMicroUSD
		if extra > 0 {
			start := time.Now()
			_ = s.store.Credit(consumerKey, extra, store.LedgerRefund, "reservation_extra_refund:"+requestID)
			s.ddIncr("billing.reservation_extra_refunds", []string{"model:" + model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_extra_refund"})
			pr.ReservedMicroUSD = reservedMicroUSD
		}
	}

	// E2E encryption
	if provider.PublicKey == "" {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, plan, "no provider with E2E encryption", http.StatusServiceUnavailable
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, plan, "provider public key invalid", http.StatusServiceUnavailable
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to generate session keys", http.StatusInternalServerError
	}

	if err := s.registry.PrepareCacheAttempt(pr, provider); err != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to prepare cache-safe request", http.StatusInternalServerError
	}
	// Pre-fix providers crash on a vision request carrying sampling penalties;
	// strip them for those providers only. Protocol-0 providers additionally get
	// a coordinator-authored prompt_cache_key only inside this sealed body.
	sealedBody, err := bodyForCacheAttempt(rawBody, requiresVision, provider, pr)
	if err != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		if errors.Is(err, errProviderBodyTooLarge) {
			excludeProviders[provider.ID] = struct{}{}
			return nil, nil, decision, plan, err.Error(), http.StatusRequestEntityTooLarge
		}
		return nil, nil, decision, plan, "failed to prepare provider request", http.StatusInternalServerError
	}
	encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
	if err != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		return nil, nil, decision, plan, "failed to encrypt request", http.StatusInternalServerError
	}
	if pr.Timing != nil {
		pr.Timing.EncryptedAt = time.Now()
	}
	ap.Mark(registry.StampEncrypted)
	pr.SessionPrivKey = &sessionKeys.PrivateKey
	// pr.ReservedMicroUSD was already set in the struct literal and may have
	// been increased by reserveAdditionalForProvider above. Don't overwrite.

	// Bound the provider write by the request-absolute first-token clock (see
	// firstTokenWriteContext): a congested write lane must not silently eat
	// the budget while the aggregator's cancel clock keeps running.
	writeCtx, cancelWrite := firstTokenWriteContext(
		r.Context(), receivedAt, requestDeadline)
	ap.Mark(registry.StampWriteSubmitted)
	_, writeErr := writeProviderInferenceRequestDeferred(
		writeCtx,
		provider,
		providerInferenceFrameBuilder(
			requestID, encrypted.EphemeralPublicKey, encrypted.Ciphertext, pr),
		func(metadata registry.TextFrameWriteMetadata) {
			if pr.Timing != nil {
				pr.Timing.DispatchedAt = metadata.DequeuedAt
			}
			if onDispatched != nil {
				onDispatched()
			}
			ap.MarkAt(registry.StampWriteDequeued, metadata.DequeuedAt)
		},
	)
	cancelWrite()
	if writeErr == nil {
		ap.Mark(registry.StampWriteDone)
	}
	if writeErr != nil {
		s.registry.ForgetCacheAttempt(pr)
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		if errors.Is(writeErr, context.DeadlineExceeded) ||
			errors.Is(writeErr, errFirstContentDeadlineAtWriter) {
			// The writer either discarded the frame before handoff or aborted
			// its connection during an in-flight write. Cancel defensively in
			// case the provider decoded the final bytes before disconnect.
			ap.Mark(registry.StampCancelSent)
			s.sendProviderCancel(provider, requestID)
			return nil, nil, decision, plan, errFirstContentDeadlineExpired, http.StatusGatewayTimeout
		}
		return nil, nil, decision, plan, "failed to send request to provider", http.StatusBadGateway
	}
	pendingCleanup = false

	return provider, pr, decision, plan, "", 0
}

// releaseUnsentDispatch returns a reservation after frame construction or
// socket handoff fails. Resolving speculative completion arbitration first
// guarantees a provider completion already waiting off the read loop cannot
// remain stranded after pending state is removed.
func (s *Server) releaseUnsentDispatch(
	provider *registry.Provider,
	pr *registry.PendingRequest,
) {
	if provider == nil || pr == nil {
		return
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	provider.RemovePending(pr.RequestID)
	s.registry.SetProviderIdle(provider.ID)
}

// penaltySafeProviderVersion is the first provider release whose VLM penalty
// path handles repetition/presence/frequency penalties without crashing (the
// TokenRing 2D-prompt fix). Providers below it crash on a vision request that
// carries any of these fields, so the coordinator strips them before sealing
// for such a provider. Keep in sync with the release that ships the fix.
const penaltySafeProviderVersion = "0.6.7"

// visionPenaltyFields crash the pre-fix VLM penalty path on image requests.
var visionPenaltyFields = []string{"repetition_penalty", "presence_penalty", "frequency_penalty"}

// bodyForProvider returns the request body to seal for `provider`. It equals
// rawBody, except a vision request routed to a pre-fix provider has the
// crash-inducing penalty fields stripped. Fixed providers receive the penalties
// unchanged. Per-provider (not pre-routing) so a retry on a fixed provider keeps
// them. Remove once MIN_PROVIDER_VERSION clears all pre-fix builds.
func bodyForProvider(rawBody []byte, requiresVision bool, provider *registry.Provider) []byte {
	if !requiresVision {
		return rawBody
	}
	if provider.Version != "" && !semverLess(provider.Version, penaltySafeProviderVersion) {
		return rawBody // fixed provider — pass penalties through
	}
	// A body carrying none of the penalty fields at its top level is returned
	// unchanged without decoding it — the same outcome the decode path reaches
	// through changed=false, minus a full-body parse per sizing probe.
	if has, ok := topLevelObjectHasAnyKey(rawBody, visionPenaltyFields); ok && !has {
		return rawBody
	}
	parsed, err := decodeInferenceJSONObject(rawBody)
	if err != nil {
		return rawBody
	}
	changed := false
	for _, key := range visionPenaltyFields {
		if _, ok := parsed[key]; ok {
			delete(parsed, key)
			changed = true
		}
	}
	if !changed {
		return rawBody
	}
	if stripped, err := marshalForwardBody(parsed); err == nil {
		return stripped
	}
	return rawBody
}

var errProviderBodyTooLarge = errors.New("provider request body too large")

type providerBodyTooLargeError struct {
	size int
}

func (e *providerBodyTooLargeError) Error() string {
	return fmt.Sprintf("%s: %d bytes exceeds the %d-byte limit after cache isolation",
		errProviderBodyTooLarge, e.size, maxInferenceBodyBytes)
}

func (e *providerBodyTooLargeError) Unwrap() error {
	return errProviderBodyTooLarge
}

func oversizedProviderBodyBytes(err error) int {
	var sizeErr *providerBodyTooLargeError
	if errors.As(err, &sizeErr) {
		return sizeErr.size
	}
	return 0
}

func legacyCacheBustBodyBytes(
	rawBody []byte,
	requiresVision bool,
	provider *registry.Provider,
) (int, error) {
	if provider == nil {
		return 0, nil
	}
	return cacheAttemptSizeError(
		bodyForProvider(rawBody, requiresVision, provider),
		strings.Repeat("x", registry.LegacyCacheBustKeyLength))
}

func providerBodySizeError(
	rawBody []byte,
	requiresVision bool,
	provider *registry.Provider,
) (int, error) {
	if provider == nil {
		return 0, nil
	}
	provider.Mu().Lock()
	usesLegacyCacheBust := provider.PrefixCacheProtocol < 1
	provider.Mu().Unlock()
	legacyKey := ""
	if usesLegacyCacheBust {
		legacyKey = strings.Repeat("x", registry.LegacyCacheBustKeyLength)
	}
	return cacheAttemptSizeError(
		bodyForProvider(rawBody, requiresVision, provider), legacyKey)
}

func minimumLegacyCacheBustOverflow(rawBody []byte, requiresVision bool) (int, error) {
	// An empty-version provider exercises the only provider-specific shrinking
	// transform: legacy vision penalty removal. Raise a fleet-wide protocol floor
	// only when even that smallest valid protocol-0 body exceeds the cap.
	return legacyCacheBustBodyBytes(rawBody, requiresVision, &registry.Provider{})
}

func routingTraitsForProviderBody(
	hasTools bool,
	providerBody []byte,
	requiresVision bool,
) (registry.RequestTraits, error) {
	traits := registry.RequestTraits{HasTools: hasTools}
	_, err := minimumLegacyCacheBustOverflow(providerBody, requiresVision)
	if errors.Is(err, errProviderBodyTooLarge) {
		traits.MinPrefixCacheProtocol = 1
	}
	return traits, err
}

// bodyForCacheAttempt returns the body to seal for one dispatch attempt: the
// provider-specific body (bodyForProvider) with the protocol-0 cache-bust key
// added as prompt_cache_key when the attempt carries one, size-checked
// against the sealed-frame cap.
func bodyForCacheAttempt(rawBody []byte, requiresVision bool, provider *registry.Provider, pr *registry.PendingRequest) ([]byte, error) {
	body := bodyForProvider(rawBody, requiresVision, provider)
	if pr == nil || pr.LegacyCacheBustKey == "" {
		if len(body) > maxInferenceBodyBytes {
			return nil, &providerBodyTooLargeError{size: len(body)}
		}
		return body, nil
	}
	keyJSON, err := json.Marshal(pr.LegacyCacheBustKey)
	if err != nil {
		return nil, err
	}
	sealed, ok := spliceTopLevelMember(body, legacyCacheBustField, keyJSON)
	if !ok {
		if sealed, err = sealLegacyCacheBust(body, keyJSON); err != nil {
			return nil, err
		}
	}
	if len(sealed) > maxInferenceBodyBytes {
		return nil, &providerBodyTooLargeError{size: len(sealed)}
	}
	return sealed, nil
}

// defaultMaxOutputTokens is the ceiling injected into requests that don't set
// max_tokens. It bounds the worst-case cost of a single inference so the
// pre-flight balance reservation covers the entire generation; without this
// cap a consumer could stream output exceeding their reservation and the
// post-inference charge would fail silently (see GitHub issue #33). Consumers
// who need longer generations must set max_tokens explicitly and carry the
// balance to cover it.
const defaultMaxOutputTokens = 8192

// explicitMaxTokens returns the consumer-specified max output tokens from any
// of the recognized field names, or 0 if none were set.
func explicitMaxTokens(parsed map[string]any) int {
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if n, ok := intFromRequestValue(parsed[key]); ok && n > 0 {
			return n
		}
	}
	return 0
}

// reservationCost is the pre-flight worst-case cost for a text inference
// request. It mirrors the platform-price branch of handleComplete's billing
// so the reservation covers any platform-level custom price for the model;
// without this, a platform override above the built-in default would leave
// the reservation short and the post-inference clamp would silently
// undercharge. Provider-specific custom prices are not known until dispatch
// commits to a provider, so a provider that sets a custom price above the
// platform rate accepts revenue capped at the reservation.
func (s *Server) reservationCost(model string, promptTokens, maxTokens int) int64 {
	customIn, customOut, hasCustom := s.store.GetModelPrice("platform", model)
	return payments.CalculateCostWithOverrides(model, promptTokens, maxTokens, customIn, customOut, hasCustom)
}

func (s *Server) refundReservedBalance(pr *registry.PendingRequest, reference string) bool {
	if pr == nil || pr.ReservedMicroUSD <= 0 {
		return false
	}
	if reference == "" {
		reference = "reservation_refund:" + pr.RequestID
	}
	start := time.Now()
	finalized, err := pr.FinalizeReservation(func() error {
		if pr.ServiceReservation {
			s.releaseServiceReservation(pr, "refund")
			return nil
		}
		return s.store.Credit(pr.ConsumerKey, pr.ReservedMicroUSD, store.LedgerRefund, reference)
	})
	if err != nil {
		s.logger.Error("failed to refund reservation",
			"request_id", pr.RequestID,
			"consumer_key", pr.ConsumerKey,
			"reserved_micro_usd", pr.ReservedMicroUSD,
			"error", err,
		)
		return false
	}
	if !finalized {
		return false
	}
	tags := []string{"model:" + pr.Model, "mode:" + reservationMetricMode(pr.ServiceReservation)}
	s.ddIncr("billing.reservation_refunds", tags)
	if !pr.ServiceReservation {
		s.ddIncr("billing.reservation_releases", append(tags, "reason:refund"))
		s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
	}
	return true
}

// routeLatencyEWMAAlpha weights the newest attempt-0 route-latency sample in
// the distress EWMA: ~10 healthy requests pull a degraded average back under
// the threshold once the collapse clears.
const routeLatencyEWMAAlpha = 0.2

// degradedRouteEWMAThresholdMs is the attempt-0 route-latency EWMA above which
// estimateRetryAfter switches from the queue-depth heuristic to distress
// scaling. Healthy routing runs ~40ms; anything over a second means the
// coordinator itself is the bottleneck.
const degradedRouteEWMAThresholdMs = 1000.0

// maxDistressRetryAfter caps the distress-scaled Retry-After (seconds).
const maxDistressRetryAfter = 60

// noteAttempt0RouteLatency folds one attempt-0 route latency (ReceivedAt →
// RoutedAt) into the distress EWMA. Called from dispatchWithReserver where
// RoutedAt is stamped; negative samples (clock skew) are dropped.
func (s *Server) noteAttempt0RouteLatency(d time.Duration) {
	ms := float64(d) / float64(time.Millisecond)
	if ms < 0 {
		return
	}
	s.routeLatencyMu.Lock()
	if s.routeLatencyEWMAMs == 0 {
		s.routeLatencyEWMAMs = ms
	} else {
		s.routeLatencyEWMAMs = routeLatencyEWMAAlpha*ms +
			(1-routeLatencyEWMAAlpha)*s.routeLatencyEWMAMs
	}
	s.routeLatencyMu.Unlock()
}

// attempt0RouteEWMAMs reads the current attempt-0 route-latency EWMA (ms).
func (s *Server) attempt0RouteEWMAMs() float64 {
	s.routeLatencyMu.Lock()
	defer s.routeLatencyMu.Unlock()
	return s.routeLatencyEWMAMs
}

// estimateRetryAfter returns a suggested wait time in seconds before retrying
// a request for the given model. Based on queue depth as a rough proxy for
// fleet backlog. OpenRouter uses the Retry-After header to schedule retries.
//
// Distress scaling (2026-09-01 congestion collapse): queue depth alone was a
// LIAR under CPU saturation — the queue was empty (nothing could even reach
// it), so every 429 carried "Retry-After: 2" and upstream obligingly hammered
// the coordinator every 2s, sustaining the death loop. When the attempt-0
// route-latency EWMA shows routing itself is degraded (> 1s), the answer
// scales with the observed degradation — max(base, ceil(EWMA seconds)×5),
// capped at 60s — so upstream backoff actually relieves pressure. Queue-depth
// behavior is unchanged while routing is healthy.
func (s *Server) estimateRetryAfter(model string) int {
	estimate := 2 // Light load, retry soon
	if queueDepth := s.registry.Queue().QueueSize(model); queueDepth > 0 {
		// Rough estimate: each queued request takes ~3 seconds to drain.
		estimate = queueDepth * 3
		if estimate < 2 {
			estimate = 2
		}
		if estimate > 30 {
			estimate = 30
		}
	}
	if ewmaMs := s.attempt0RouteEWMAMs(); ewmaMs > degradedRouteEWMAThresholdMs {
		scaled := int(math.Ceil(ewmaMs/1000)) * 5
		if scaled > maxDistressRetryAfter {
			scaled = maxDistressRetryAfter
		}
		if scaled > estimate {
			estimate = scaled
		}
	}
	return estimate
}

// writeServiceUnavailable writes a retryable 503 with a Retry-After header so
// clients (and OpenRouter) can schedule the retry instead of blind backoff.
func (s *Server) writeServiceUnavailable(w http.ResponseWriter, model string) {
	w.Header().Set("Retry-After", strconv.Itoa(s.estimateRetryAfter(model)))
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
		"service temporarily unavailable — please retry"))
}

func providerHasPayoutDestination(provider *registry.Provider) bool {
	if provider == nil {
		return false
	}
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	return provider.AccountID != ""
}

func providerPricingKeys(provider *registry.Provider) string {
	if provider == nil {
		return ""
	}
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	return provider.AccountID
}

func (s *Server) providerReservationCost(provider *registry.Provider, model string, promptTokens, maxTokens int) int64 {
	accountID := providerPricingKeys(provider)
	if accountID != "" {
		customIn, customOut, hasCustom := s.store.GetModelPrice(accountID, model)
		if hasCustom {
			return payments.CalculateCostWithOverrides(model, promptTokens, maxTokens, customIn, customOut, true)
		}
	}
	return s.reservationCost(model, promptTokens, maxTokens)
}

// isServiceConsumer reports whether the account is a service/wholesale account
// (e.g. OpenRouter). Such accounts are billed at the advertised platform price,
// so the provider-price reservation top-up and provider custom pricing are
// skipped for them. A failed lookup falls back to false (normal consumer).
func (s *Server) isServiceConsumer(accountID string) bool {
	if accountID == "" {
		return false
	}
	if u, err := s.store.GetUserByAccountID(accountID); err == nil && u != nil {
		return u.Role == store.RoleService
	}
	return false
}

func (s *Server) reserveAdditionalForProvider(pr *registry.PendingRequest, provider *registry.Provider) (int64, error) {
	if pr == nil {
		return 0, fmt.Errorf("pending request is required")
	}
	// Service/wholesale consumers are billed at the platform price at
	// settlement, so don't top the reservation up to a provider's higher custom
	// price — the base platform reservation already covers the actual charge.
	if s.isServiceConsumer(pr.ConsumerKey) {
		return pr.ReservedMicroUSD, nil
	}
	required := s.providerReservationCost(provider, pr.Model, pr.EstimatedPromptTokens, pr.RequestedMaxTokens)
	if required <= pr.ReservedMicroUSD {
		return pr.ReservedMicroUSD, nil
	}
	// Per-key spend cap re-check against the provider-specific total: the
	// initial cap check only saw the platform reservation, so a provider whose
	// custom price exceeds it could otherwise push a capped key over its limit
	// in a single request. Treat a cap breach like insufficient funds so the
	// caller excludes this provider (a cheaper one may still fit) and, if none
	// fit, the request fails with 402. Checked BEFORE charging the top-up.
	if pr.KeyID != "" && pr.KeyLimitMicroUSD != nil {
		since := store.KeySpendWindowStart(pr.KeyLimitReset, time.Now())
		if s.store.KeySpendSince(pr.KeyID, since)+required > *pr.KeyLimitMicroUSD {
			return pr.ReservedMicroUSD, store.ErrInsufficientBalance
		}
	}
	extra := required - pr.ReservedMicroUSD
	if err := s.ledger.Charge(pr.ConsumerKey, extra, "reserve:"+pr.ConsumerKey); err != nil {
		return pr.ReservedMicroUSD, err
	}
	pr.ReservedMicroUSD = required
	s.ddHistogram("billing.reserved_micro_usd", float64(required), []string{"model:" + pr.Model})
	return required, nil
}

// ensureMaxTokensBound injects a max-tokens bound into parsed when the
// consumer didn't specify any max-tokens field, so the outgoing request to
// the provider is bounded by the amount we reserve upfront. The bound is
// the model's max_output_length from the registry (or defaultMaxOutputTokens
// as fallback). The injected field name depends on the API flavor: Responses
// API uses max_output_tokens, everything else uses max_tokens. Returns true
// when an injection occurred, so the caller can re-marshal the outgoing body
// if needed.
func ensureMaxTokensBound(parsed map[string]any, isResponsesAPI bool, bound int) bool {
	if n := explicitMaxTokens(parsed); n > 0 {
		// Normalize alias fields the provider engine doesn't read: a chat
		// request bounded only via max_completion_tokens (the OpenAI-preferred
		// spelling) must still reach the provider as max_tokens, or the bound
		// is silently ignored.
		if !isResponsesAPI {
			if cur, ok := intFromRequestValue(parsed["max_tokens"]); !ok || cur <= 0 {
				parsed["max_tokens"] = n
				return true
			}
		}
		return false
	}
	if isResponsesAPI {
		parsed["max_output_tokens"] = bound
	} else {
		parsed["max_tokens"] = bound
	}
	return true
}

// handleChatCompletions handles POST /v1/chat/completions.
//
// This is the main inference endpoint. It validates the request, finds an
// available provider for the requested model, forwards the request via
// WebSocket, and either streams SSE chunks or assembles a complete response.
//
// Chat-completions bodies are passed through to the provider, preserving all
// OpenAI-compatible fields. Responses API bodies are lowered into that same
// provider-facing chat shape while their original parsed form remains the
// source for accounting and consumer-facing response conversion.
func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.newRequestProfile(r, "", "", false)

	// Shared prelude: read body, normalize tool schemas, parse, require a model,
	// enforce the per-key model allowlist. (See parseInferencePrelude.)
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	// body is the provider-bound request: every rewrite below mutates
	// body.parsed (== parsed) and marks it dirty; the bytes are serialized ONCE,
	// at the single serialization point ahead of the first consumer of the
	// provider body. originalRawBody stays the caller's untouched input.
	body := &prelude.body
	originalRawBody := prelude.originalRawBody
	parsed := prelude.parsed
	model := prelude.model
	runtimeDefaults := newModelRuntimeDefaults(parsed)
	_, reasoningProvided := parsed["reasoning"]

	// Accept either chat completions format (messages) or Responses API format
	// (input). Responses requests are lowered before the provider body is sealed.
	messages, _ := parsed["messages"].([]any)
	input := parsed["input"]
	if len(messages) == 0 && input == nil {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "messages_required",
			httpStatus:      http.StatusBadRequest,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "messages or input is required"))
		return
	}

	// Multiple choices per request are not supported — fail loudly instead of
	// silently returning a single choice the consumer didn't ask for.
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "bad_param",
			httpStatus:      http.StatusBadRequest,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			n:               copies,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"n > 1 is not supported", withParam("n")))
		return
	}

	var allowedProviderSerials []string
	if stripProviderRoutingFields(parsed) {
		body.markDirty()
	}
	if applyMetadataDetailsRequest(r, parsed) {
		body.markDirty()
	}

	// "Use my own machine, for free" opt-in. The signal is the
	// X-Darkbloom-Route header (OpenAI-client-safe: invisible to the body
	// schema) OR a per-key hard ceiling. The header can only *request*
	// self-routing; it cannot name a machine — ownership is matched on the
	// coordinator-stamped provider AccountID, so nothing here is forgeable.
	policy := s.resolveSelfRoutePolicy(r)

	isResponsesAPI := input != nil && len(messages) == 0
	// Tool-constraint validation must judge the PRE-normalization tools (a
	// normalization marker in the caller's body is forged). On the chat surface
	// that is the parsed map with the caller's original tools restored; the
	// Responses surface needs the input→chat lowering, which works on bytes, so
	// the untouched input is lowered and parsed once.
	var validatedPolicy validatedToolConstraintPolicy
	var validationErr error
	if isResponsesAPI {
		loweredConstraintBody, err := promptcontract.LowerProviderBody(
			promptcontract.EndpointResponses, originalRawBody)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse(
				"invalid_request_error", err.Error()))
			return
		}
		validatedPolicy, validationErr = validateToolConstraintPolicy(loweredConstraintBody)
	} else {
		validatedPolicy, validationErr = validateParsedToolConstraintPolicy(
			constraintView(parsed, prelude.originalTools))
	}
	if validationErr != nil {
		s.recordToolConstraintMetric(validatedPolicy.mode, "compile_rejection")
		writeToolConstraintValidationError(w, validationErr)
		return
	}
	// Derive request-shape traits before alias resolution. During a
	// mixed-version rollout Desired may have ordinary providers while Previous
	// has the only provider capable of enforcing this exact tool policy. One
	// walk of the message tree yields the media count, the tools flag, and the
	// routing/billing token estimates (consumed below, after the rewrites). It
	// runs after constraint validation so a rejected tool policy on a large
	// body never pays the walk.
	shape := introspectRequest(parsed)
	requiresVision := shape.requiresVision()
	hasTools := shape.hasTools
	validatedMode := validatedPolicy.mode
	toolChoiceName := validatedPolicy.name
	parallelToolCalls := validatedPolicy.parallel
	s.recordToolConstraintMetric(validatedMode, "requested")
	requiresToolConstraint := validatedMode.requiresInferenceConstraint()
	if requiresToolConstraint && requiresVision {
		writeJSON(w, http.StatusBadRequest, errorResponse(
			"invalid_request_error",
			"inference-enforced tool_choice is not supported for multimodal requests",
			withParam("tool_choice")))
		return
	}
	aliasTraits := registry.RequestTraits{
		HasTools:               hasTools,
		RequiresToolConstraint: requiresToolConstraint,
		ToolChoiceMode:         string(validatedMode),
		ToolChoiceName:         toolChoiceName,
		ParallelToolCalls:      parallelToolCalls,
	}

	// Resolve a public alias (e.g. "gemma-4-26b") to a concrete build id, now
	// that coordinator routing constraints and self-route policy are known so
	// the pick only considers builds the constrained provider set can actually
	// serve. From here on `model` is the build (routing/billing/serving) while
	// `publicModel` is echoed back so the consumer never sees the quant.
	buildModel, publicModel, modelRewritten, ok := s.resolveRequestedBuild(
		parsed, model, allowedProviderSerials, policy, aliasTraits)
	if !ok {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "model_resolution",
			reasonCode:      "model_unavailable",
			httpStatus:      http.StatusServiceUnavailable,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), withParam("model")))
		return
	}
	model = buildModel
	if modelRewritten {
		body.markDirty()
	}
	user := auth.UserFromContext(r.Context())
	serviceChatConsumer := r.URL.Path == "/v1/chat/completions" &&
		user != nil && user.Role == store.RoleService
	if applyResolvedModelReasoningPolicy(parsed, model, serviceChatConsumer, reasoningProvided) {
		body.markDirty()
	}

	// Shared media/tools fail-fast. Chat completions additionally rejects media
	// sent via the Responses API surface (input-without-messages), because the
	// Responses→chat lowering doesn't carry image/video parts through.
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		requiresToolConstraint, string(validatedMode),
		input != nil && len(messages) == 0, policy, allowedProviderSerials) {
		return
	}
	// Remote media URL gate (phase 1, pre-billing). With the media resolver
	// enabled (default), remote http(s) image_url/video_url links are fetched
	// and inlined as data: URIs AFTER the balance reservation (resolveRemoteMedia
	// below); here we fail fast only the cases that must never fetch: sealed
	// requests, remote refs in shapes the resolver doesn't handle, and the
	// resolver-disabled fallback (the legacy one-clean-400, the provider VLM
	// path being data:-only).
	if s.gateRemoteMediaPreDispatch(w, r, parsed, model, publicModel, requiresVision, hasTools) {
		return
	}

	// Inject model-specific request defaults from the registry, then apply the
	// model's max_tokens bound. Single DB lookup (cached for platform prices).
	maxOutputBound := defaultMaxOutputTokens
	// modelMaxContext is the model's max context window (0 = unknown), used by the
	// servability gate. Lifted out of the record block so it is in scope at the
	// preflight below.
	modelMaxContext := 0
	registryReadStart := time.Now()
	var resolvedRuntimeParameters map[string]any
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		profileDBCall(rp, registryReadStart)
		resolvedRuntimeParameters = rec.RuntimeParameters
		if runtimeDefaults.apply(parsed, rec.RuntimeParameters) {
			body.markDirty()
		}
		// Use the registry's max_output_length as the default max_tokens
		// bound instead of the hardcoded 8192. This lets models like
		// GPT-OSS 20B (32K output) generate longer responses when the
		// consumer omits max_tokens.
		if rec.MaxOutputLength > 0 {
			maxOutputBound = rec.MaxOutputLength
		}
		modelMaxContext = rec.MaxContextLength
	}
	if err := validateResolvedToolConstraintParser(
		parsed, validatedMode, model, s.registry.ModelType(model),
		resolvedRuntimeParameters,
	); err != nil {
		s.recordToolConstraintMetric(validatedMode, "compile_rejection")
		writeToolConstraintValidationError(w, err)
		return
	}

	// Bound the generation so the pre-flight reservation covers it. If the
	// consumer didn't set max_tokens, inject the model's max_output_length
	// (or defaultMaxOutputTokens as fallback). Without this bound the
	// provider could return more tokens than we reserved for, and the
	// silent post-inference charge failure would hand the consumer free
	// inference (GitHub issue #33).
	if ensureMaxTokensBound(parsed, isResponsesAPI, maxOutputBound) {
		body.markDirty()
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := shape.routingPromptTokens(parsed)
	billingPromptTokens := shape.billingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	deadline := s.FirstContentDeadline(model, estimatedPromptTokens)
	timing.ParsedAt = time.Now()
	rp.Mark(registry.StampReqParsed)
	if s.shedIfModelRejected(w, r, parsed, policy, publicModel, model, stream, estimatedPromptTokens, requestedMaxTokens, requiresVision, hasTools) {
		return
	}

	// Single serialization point: every rewrite above (stop, stripped fields,
	// alias, reasoning policy, runtime defaults, max_tokens) landed in parsed;
	// serialize once here — or hand the caller's exact bytes through when
	// nothing changed.
	rawBody, err := body.current()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse(
			"server_error", "failed to prepare inference request"))
		return
	}
	providerBody := rawBody
	if isResponsesAPI {
		loweredProviderBody, err := promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rawBody)
		if err != nil {
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "validation",
				reasonCode:            "bad_param",
				httpStatus:            http.StatusBadRequest,
				keyID:                 keyIDFromContext(r.Context()),
				consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:        publicModel,
				resolvedModel:         model,
				stream:                stream,
				estimatedPromptTokens: estimatedPromptTokens,
				requestedMaxTokens:    requestedMaxTokens,
				requiresVision:        requiresVision,
				hasTools:              hasTools,
				params:                rejectionSamplingParams(parsed),
			})
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return
		}
		providerBody = loweredProviderBody
	}
	// Candidate provider bodies (the resolved build, the alias fallback build
	// the preflight probes) and the routing verdicts derived from them are
	// memoized per request: traits, the protocol-0 size verdict, and dispatch
	// all reuse one serialization per candidate. When the body above is the
	// coordinator's own serialization, the resolved build is seeded with it —
	// parsed is fully reconciled for that build, so a rebuild would produce the
	// same bytes. A verbatim caller body is NOT a substitute (its whitespace,
	// key order and escapes differ from the serialized form the size verdicts
	// have always measured), so that rare case builds its candidate as before.
	bodies := newProviderBodyMemo(func(candidateModel string) ([]byte, error) {
		return s.candidateProviderBody(parsed, runtimeDefaults, candidateModel,
			serviceChatConsumer, reasoningProvided, isResponsesAPI)
	}, hasTools, requiresVision)
	if body.serialized {
		bodies.seed(model, providerBody)
	}
	routingTraitsForModel := func(candidateModel string) registry.RequestTraits {
		traits, ok := bodies.traits(candidateModel)
		if !ok {
			traits = registry.RequestTraits{HasTools: hasTools}
		}
		traits.RequiresToolConstraint = requiresToolConstraint
		traits.ToolChoiceMode = string(validatedMode)
		traits.ToolChoiceName = toolChoiceName
		traits.ParallelToolCalls = parallelToolCalls
		return traits
	}
	providerBodyErrorForModel := bodies.sizeError
	routingTraits := routingTraitsForModel(model)

	// Per-account token rate limiting (ITPM/OTPM) — the industry-standard
	// token throttle alongside RPM. Charged upfront from the input estimate
	// and the bounded max_tokens (OpenAI-style). Runs before the balance
	// reservation so a throttled request never touches billing.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation + per-key spend cap (see
	// reserveInferenceBalance). Self-route and a nil billing backend are free.
	reservedMicroUSD, serviceReservation, reserveHandled := s.reserveInferenceBalance(w, r, parsed, balanceReservationParams{
		model:                 model,
		publicModel:           publicModel,
		billingPromptTokens:   billingPromptTokens,
		estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens:    requestedMaxTokens,
		stream:                stream,
		requiresVision:        requiresVision,
		hasTools:              hasTools,
		policy:                policy,
	})
	if reserveHandled {
		return
	}
	timing.ReservedAt = time.Now()
	rp.Mark(registry.StampReqReserved)

	// Refund reservation on early errors (before inference starts).
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.releaseInitialReservation(consumerKeyFromContext(r.Context()), model, reservedMicroUSD, serviceReservation)
		}
	}

	// Reject requests for models not in the catalog.
	if !policy.enabled && !s.registry.IsModelInCatalog(model) {
		refundReservation()
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "model_resolution",
			reasonCode:            "model_not_found",
			httpStatus:            http.StatusNotFound,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                stream,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), withParam("model")))
		return
	}

	// Resolve remote http(s) image_url/video_url links into inline base64 data:
	// URIs (phase 2 — see media_resolve.go) — AFTER token admission, the balance
	// reservation, and the catalog check, so network I/O is gated behind the
	// cost gates: an authenticated but unfunded/over-quota request (or one for a
	// nonexistent model) can never drive coordinator-side fetches. The token &
	// routing estimates above count media parts flatly (300/1500 per part), so
	// they don't need the inlined bytes. The billing reservation is refunded on
	// any failure, and topped up below on success — it was taken while the media
	// was still a ~100-byte URL. parsed is mutated in place, so every view
	// derived from the pre-inline body is refreshed via refreshForwardBody.
	var mediaInlined bool
	rawBody, mediaInlined, ok = s.resolveRemoteMedia(w, r, rawBody, parsed, timing, mediaResolveMeta{
		model:                 model,
		publicModel:           publicModel,
		stream:                stream,
		estimatedPromptTokens: estimatedPromptTokens,
		firstContentDeadline:  deadline,
		requestedMaxTokens:    requestedMaxTokens,
		hasTools:              hasTools,
		requiresVision:        requiresVision,
		selfRoute:             policy.enabled,
		ownerAccountID:        policy.ownerAccountID,
		traits:                routingTraits,
	})
	if !ok {
		refundReservation()
		// Token-rate admission is intentionally NOT refunded: this matches every
		// other post-admission validation failure and makes blocked/invalid URL
		// probes consume the caller's input/output token quota.
		return
	}

	// refreshForwardBody re-derives every view of the provider-bound request from
	// a freshly marshaled `parsed`: the threaded rawBody, the body actually
	// forwarded to the provider (re-lowered input→chat on the Responses surface,
	// which can itself fail with a 400), the memoized candidate bodies (every
	// earlier candidate described a parsed that no longer exists), and the
	// routing traits computed from it. Any in-place mutation of `parsed` MUST go
	// through it — an alias fallback rewriting the model, or remote media being
	// inlined as data: URIs. Returns false after writing a terminal response.
	refreshForwardBody := func(forwardBytes []byte, forModel string) bool {
		rawBody = forwardBytes
		body.replace(forwardBytes)
		bodies.reset()
		if !isResponsesAPI {
			providerBody = rawBody
			bodies.seed(forModel, providerBody)
			routingTraits = routingTraitsForModel(forModel)
			return true
		}
		var err error
		providerBody, err = promptcontract.LowerProviderBody(promptcontract.EndpointResponses, rawBody)
		if err != nil {
			refundReservation()
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "validation",
				reasonCode:            "bad_param",
				httpStatus:            http.StatusBadRequest,
				keyID:                 keyIDFromContext(r.Context()),
				consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:        publicModel,
				resolvedModel:         forModel,
				stream:                stream,
				estimatedPromptTokens: estimatedPromptTokens,
				requestedMaxTokens:    requestedMaxTokens,
				requiresVision:        requiresVision,
				hasTools:              hasTools,
				params:                rejectionSamplingParams(parsed),
			})
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return false
		}
		bodies.seed(forModel, providerBody)
		routingTraits = routingTraitsForModel(forModel)
		return true
	}

	// Remote media was fetched and inlined into `parsed` above, so `providerBody`
	// (captured before the resolve) and the routing traits derived from it now
	// describe a body that no longer exists. Without this refresh the coordinator
	// pays for the fetch and then seals and dispatches the ORIGINAL body still
	// carrying the http(s) URL, which the provider's data:-only guard rejects.
	if mediaInlined {
		if !refreshForwardBody(rawBody, model) {
			return
		}
		// The reservation was taken against a body where the image was a short
		// URL, so estimateBillingPromptTokens — the guaranteed len(bytes) >= tokens
		// upper bound the settlement path relies on — was computed over ~100 bytes
		// of URL instead of the inlined media. Re-reserve against the real body
		// before dispatch; otherwise settlement's 2x-reservation overage clamp
		// silently absorbs the difference and underpays the provider.
		var topUpHandled bool
		reservedMicroUSD, topUpHandled = s.topUpReservationForInlinedMedia(w, r, parsed, balanceReservationParams{
			model:                 model,
			publicModel:           publicModel,
			billingPromptTokens:   estimateBillingPromptTokens(parsed),
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			stream:                stream,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			policy:                policy,
		}, reservedMicroUSD)
		if topUpHandled {
			refundReservation()
			return
		}
	}

	// Shared routing/capacity admission preflight (self-route / prefer / public
	// capacity+TTFT gate — see runInferenceAdmission). On the chat path an alias
	// fallback must refresh the threaded rawBody; thread that as the
	// onModelFallback callback. resolvedModel uses the new build to match the
	// pre-extraction behavior.
	onModelFallback := func(newModel string) bool {
		var runtimeParameters map[string]any
		if rec, err := s.store.GetModelRegistryRecord(newModel); err == nil {
			runtimeParameters = rec.RuntimeParameters
			runtimeDefaults.apply(parsed, runtimeParameters)
		} else {
			runtimeDefaults.apply(parsed, nil)
		}
		if err := validateResolvedToolConstraintParser(
			parsed, validatedMode, newModel, s.registry.ModelType(newModel),
			runtimeParameters,
		); err != nil {
			s.recordToolConstraintMetric(validatedMode, "compile_rejection")
			writeToolConstraintValidationError(w, err)
			refundReservation()
			return false
		}
		applyResolvedModelReasoningPolicy(parsed, newModel, serviceChatConsumer, reasoningProvided)
		// maybeFallbackAlias rewrote parsed["model"]; the defaults and reasoning
		// policy above may have moved more. One serialization covers all of it.
		body.markDirty()
		forwardBytes, err := body.current()
		if err != nil {
			refundReservation()
			writeJSON(w, http.StatusInternalServerError, errorResponse(
				"server_error", "failed to prepare inference request"))
			return false
		}
		return refreshForwardBody(forwardBytes, newModel)
	}
	var preflightHandled bool
	preflightStart := time.Now()
	model, preflightHandled = s.runInferenceAdmission(w, r, parsed, inferenceAdmissionParams{
		model:                     model,
		publicModel:               publicModel,
		stream:                    stream,
		estimatedPromptTokens:     estimatedPromptTokens,
		requestedMaxTokens:        requestedMaxTokens,
		requiresVision:            requiresVision,
		hasTools:                  hasTools,
		traits:                    &routingTraits,
		traitsForModel:            routingTraitsForModel,
		providerBodyErrorForModel: providerBodyErrorForModel,
		modelMaxContext:           modelMaxContext,
		allowedProviderSerials:    allowedProviderSerials,
		deadline:                  deadline,
		policy:                    policy,
		refundReservation:         refundReservation,
		onModelFallback:           onModelFallback,
	})
	if rp != nil {
		rp.PreflightUS = time.Since(preflightStart).Microseconds()
		rp.Mark(registry.StampReqPreflightDone)
		if preflightHandled {
			rp.PreflightOutcome = "handled"
		} else {
			rp.PreflightOutcome = "passed"
		}
	}
	if preflightHandled {
		return
	}

	// Dispatch to a provider with speculative TTFT-aware dispatch. On the
	// first attempt we dispatch to the best provider (primary), and start a
	// speculative timer at 50% of the TTFT deadline. If the primary hasn't
	// produced a first chunk by the speculative timer, a backup provider is
	// dispatched in parallel and both race. If the primary fails outright
	// (error before the speculative timer), up to maxDispatchAttempts
	// sequential retries are performed without speculation.
	//
	// No HTTP response is written until a provider starts generating, so
	// retries and speculative dispatch are invisible to the consumer.
	// Dispatch is driven by the per-request state machine in dispatch.go: it
	// picks a provider (or queues), runs the speculative TTFT-aware first-chunk
	// wait with an invisible backup race + failover up to maxDispatchAttempts,
	// commits exactly once, then writes attestation/timing headers and streams.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)

	// model may have been rewritten by a capacity- or TTFT-fallback above
	// (maybeFallbackAlias), so refresh the context
	// window for the FINAL build before handing it to the dispatch loop — otherwise
	// shouldStopFailover/classifyRejection would compare a provider's budget against
	// the originally-resolved model's context. Overwrite only on a successful lookup
	// (fallback builds of the same alias normally share a context window; a build
	// absent from the store keeps the prior value, matching the initial read).
	registryReadStart2 := time.Now()
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		modelMaxContext = rec.MaxContextLength
	}
	profileDBCall(rp, registryReadStart2)
	cachePlan := s.planCacheRoute(
		r.Context(), consumerKey, model, providerBody, requiresVision)
	rp.Mark(registry.StampReqPlanDone)
	if rp != nil {
		rp.Model, rp.PublicModel, rp.Stream = model, publicModel, stream
		rp.FirstContentBudgetMs = int(deadline.Milliseconds())
		rp.EstimatedPromptTokens, rp.RequestedMaxTokens = estimatedPromptTokens, requestedMaxTokens
		rp.RequiresVision, rp.HasTools = requiresVision, hasTools
		rp.BodyBytes = len(rawBody)
		if mediaInlined {
			rp.Mark(registry.StampReqMediaFetched)
		}
	}

	d := &dispatchState{
		s:                      s,
		w:                      w,
		r:                      r,
		model:                  model,
		publicModel:            publicModel,
		rawBody:                providerBody,
		consumerKey:            consumerKey,
		consumerLocation:       consumerLocation,
		reservedMicroUSD:       reservedMicroUSD,
		tokenAdmission:         tokenAdmission,
		serviceReservation:     serviceReservation,
		estimatedPromptTokens:  estimatedPromptTokens,
		requestedMaxTokens:     requestedMaxTokens,
		requiresVision:         requiresVision,
		visionImageCount:       shape.mediaParts,
		hasTools:               hasTools,
		requiresToolConstraint: requiresToolConstraint,
		toolChoiceMode:         string(validatedMode),
		toolChoiceName:         toolChoiceName,
		parallelToolCalls:      parallelToolCalls,
		isResponsesAPI:         isResponsesAPI,
		stream:                 stream,
		metadataDetails:        metadataDetailsFromRequest(r),
		policy:                 policy,
		allowedProviderSerials: allowedProviderSerials,
		cachePlan:              cachePlan,
		timing:                 timing,
		profile:                rp,
		deadline:               deadline,
		speculativeAt:          time.Duration(float64(deadline) * speculativeTimerRatio),
		modelMaxContext:        modelMaxContext,
		refundReservation:      refundReservation,
		// Track providers that failed during retry so we don't dispatch to them again.
		excludeProviders: make(map[string]struct{}),
	}
	d.run()
}

// createAPIKeyRequest is the POST /v1/keys (and rotate inherit) body. Money is
// supplied in USD; the wire never sees the secret after the create response.
type createAPIKeyRequest struct {
	Name          string     `json:"name"`
	LimitUSD      *float64   `json:"limit_usd"`
	LimitReset    string     `json:"limit_reset"`
	RPMLimit      *int64     `json:"rpm_limit"`
	ITPMLimit     *int64     `json:"itpm_limit"`
	OTPMLimit     *int64     `json:"otpm_limit"`
	AllowedModels []string   `json:"allowed_models"`
	SelfRouteOnly bool       `json:"self_route_only"`
	ExpiresAt     *time.Time `json:"expires_at"`
}

// usdToMicro converts a USD dollar amount to micro-USD (rounded).
func usdToMicro(usd float64) int64 { return int64(math.Round(usd * 1_000_000)) }

// microToUSD converts micro-USD to a USD float.
func microToUSD(micro int64) float64 { return float64(micro) / 1_000_000 }

// handleHealth handles GET /health.
// Returns the coordinator's status and the number of connected providers.
// This endpoint does not require authentication.
//
// /health is a LIVENESS probe: it returns 200 whenever the process is up, INCLUDING
// while draining. This is deliberate. The production host Caddy health-checks its
// single coordinator upstream on /health with health_status 200, so returning 503 here
// would mark the only backend down and make the admin/rollback endpoints
// (POST /v1/admin/drain {"draining":false}) and /readyz unreachable through the
// public URL — you could not undo a drain remotely. Drain/readiness lives on
// /readyz (handleReadyz, 503 while draining), which the deploy script and
// multi-backend load balancers consult to shift traffic. The body still reports
// draining=true for observability, but the status code stays 200.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, types.HealthResponse{
		Status:      "ok",
		Draining:    s.IsDraining(),
		Providers:   s.registry.ProviderCount(),
		Version:     BuildVersion,
		BuildCommit: BuildCommit,
		BuildDate:   BuildDate,
	})
}

// handleVersion returns the latest provider CLI version and download URL.
// Providers call GET /api/version to check if they need to update.
// If a release is registered in the store, uses that. Otherwise falls back
// to the hardcoded LatestProviderVersion.
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	if cached, ok := s.readCache.Get(apiVersionCacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	var resp types.VersionResponse
	// Try release table first.
	if release := s.store.GetLatestRelease(defaultReleasePlatform); release != nil {
		resp = types.VersionResponse{
			Version:      release.Version,
			Platform:     release.Platform,
			Backend:      release.Backend,
			DownloadURL:  release.URL,
			BinaryHash:   release.BinaryHash,
			BundleHash:   release.BundleHash,
			MetallibHash: release.MetallibHash,
			Changelog:    release.Changelog,
		}
	} else {
		// Fallback to hardcoded version + coordinator download.
		scheme := "https"
		if r.TLS == nil && !strings.Contains(r.Host, "darkbloom.dev") {
			scheme = "http"
		}
		downloadURL := fmt.Sprintf("%s://%s/dl/eigeninference-bundle-macos-arm64.tar.gz", scheme, r.Host)
		resp = types.VersionResponse{
			Version:     LatestProviderVersion,
			DownloadURL: downloadURL,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode version"))
		return
	}
	s.readCache.Set(apiVersionCacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// --- payment handlers ---

// handleBalance handles GET /v1/payments/balance.
// Returns the consumer's current balance in both micro-USD and USD.
func (s *Server) handleBalance(w http.ResponseWriter, r *http.Request) {
	consumerKey := consumerKeyFromContext(r.Context())
	balance := s.ledger.Balance(consumerKey)
	withdrawable := s.store.GetWithdrawableBalance(consumerKey)

	writeJSON(w, http.StatusOK, types.BalanceResponse{
		BalanceMicroUSD:      balance,
		BalanceUSD:           fmt.Sprintf("%.6f", float64(balance)/1_000_000),
		WithdrawableMicroUSD: withdrawable,
		WithdrawableUSD:      fmt.Sprintf("%.6f", float64(withdrawable)/1_000_000),
	})
}

// handleUsage handles GET /v1/payments/usage.
// Returns the consumer's inference usage history with per-request costs.
// Tries in-memory ledger first (has full detail), falls back to store
// ledger history (persists across restarts but has less detail).
func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	consumerKey := consumerKeyFromContext(r.Context())
	entries := s.ledger.Usage(consumerKey)

	// If in-memory usage is empty (coordinator restarted), build from
	// the persisted usage table which has full request details.
	if len(entries) == 0 {
		usageRecords := s.store.UsageByConsumer(consumerKey)
		for _, u := range usageRecords {
			jobID := u.RequestID
			if jobID == "" {
				jobID = u.ProviderID
			}
			model := u.Model
			if u.PublicModel != "" {
				model = u.PublicModel
			}
			entries = append(entries, payments.UsageEntry{
				JobID:            jobID,
				Model:            model,
				PromptTokens:     u.PromptTokens,
				CompletionTokens: u.CompletionTokens,
				CostMicroUSD:     u.CostMicroUSD,
				Timestamp:        u.CreatedAt,
			})
		}
	}

	writeJSON(w, http.StatusOK, types.UsageResponse{
		Usage: entries,
	})
}

// handleProviderEarnings handles GET /v1/provider/earnings?wallet=0x...
//
// Returns the provider's balance and payout history.
// No API key auth required — providers identify by provider address.
func (s *Server) handleProviderEarnings(w http.ResponseWriter, r *http.Request) {
	wallet := r.URL.Query().Get("wallet")
	if wallet == "" {
		wallet = r.Header.Get("X-Provider-Wallet")
	}
	if wallet == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "wallet address required (query param ?wallet=0x... or X-Provider-Wallet header)"))
		return
	}

	// Look up balance by provider address
	balance := s.ledger.Balance(wallet)
	history := s.ledger.LedgerHistory(wallet)
	payouts := s.ledger.AllPayouts()

	// Filter payouts to this wallet
	var walletPayouts []payments.Payout
	var totalEarned int64
	var totalJobs int
	for _, p := range payouts {
		if p.ProviderAddress == wallet {
			walletPayouts = append(walletPayouts, p)
			totalEarned += p.AmountMicroUSD
			totalJobs++
		}
	}

	// If no explicit payout records exist (for example, legacy rows created
	// before provider_payouts was introduced), reconstruct from persisted
	// ledger entries with payout type and the wallet as account ID.
	if len(walletPayouts) == 0 {
		ledgerEntries := s.store.LedgerHistory(wallet)
		for _, le := range ledgerEntries {
			if le.Type == store.LedgerPayout && le.Reference != "" {
				walletPayouts = append(walletPayouts, payments.Payout{
					ProviderAddress: wallet,
					AmountMicroUSD:  le.AmountMicroUSD,
					JobID:           le.Reference,
					Timestamp:       le.CreatedAt,
					Settled:         true,
				})
				totalEarned += le.AmountMicroUSD
				totalJobs++
			}
		}
	}

	if walletPayouts == nil {
		walletPayouts = []payments.Payout{}
	}

	writeJSON(w, http.StatusOK, types.ProviderEarningsResponse{
		BalanceMicroUSD:     balance,
		BalanceUSD:          fmt.Sprintf("%.6f", float64(balance)/1_000_000),
		TotalEarnedMicroUSD: totalEarned,
		TotalEarnedUSD:      fmt.Sprintf("%.6f", float64(totalEarned)/1_000_000),
		TotalJobs:           totalJobs,
		Payouts:             walletPayouts,
		Ledger:              history,
	})
}

// --- helpers ---

// handleCompletions handles POST /v1/completions.
// Proxies OpenAI-compatible text completions to the selected provider over the
// E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Server) handleCompletions(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/completions")
}

// handleAnthropicMessages handles POST /v1/messages.
// Proxies the Anthropic-compatible messages API to the selected provider over
// the E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Server) handleAnthropicMessages(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/messages")
}

// handleGenericInference is the shared dispatch for completions and Anthropic endpoints.
// It reads the endpoint-native body, preserves it for accounting, lowers the
// final provider body to OpenAI chat format, and reuses the same E2E encryption
// and provider routing as chat completions.
func (s *Server) handleGenericInference(w http.ResponseWriter, r *http.Request, endpoint string) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.newRequestProfile(r, "", "", false)

	// Shared prelude: read body, normalize tool schemas (Anthropic /v1/messages
	// bodies carry a top-level "tools" array too; the provider body is rebuilt
	// from parsed below, so normalizing before the unmarshal covers it), parse,
	// require a model, enforce the per-key model allowlist.
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	// This handler rebuilds its provider body from `parsed` (inferenceBody
	// below); the prelude's forward bytes are only threaded into
	// resolveRequestedModel, which never uses them here.
	rawBody := prelude.originalRawBody
	originalRawBody := prelude.originalRawBody
	parsed := prelude.parsed
	model := prelude.model
	runtimeDefaults := newModelRuntimeDefaults(parsed)
	endpointKind := promptcontract.EndpointCompletions
	if endpoint == "/v1/messages" {
		endpointKind = promptcontract.EndpointMessages
	}

	var allowedProviderSerials []string
	stripProviderRoutingFields(parsed)
	applyMetadataDetailsRequest(r, parsed)

	// "Use my own machine, for free" opt-in (see handleChatCompletions).
	policy := s.resolveSelfRoutePolicy(r)

	// Constraint validation needs the lowered chat shape. Endpoint-native
	// shapes the contract lowering cannot express — multi-prompt completions,
	// media-bearing messages — have always been forwarded verbatim (see the
	// inferenceBody fallback below), so a lowering failure is only terminal
	// for requests that actually carry tool policy to validate; tool-less
	// unsupported shapes keep the pre-existing native-forward behavior with
	// the neutral auto defaults.
	validatedPolicy := validatedToolConstraintPolicy{
		mode: toolChoiceAuto, parallel: true,
	}
	constraintBody, constraintLowerErr := promptcontract.LowerProviderBody(
		endpointKind, originalRawBody)
	if constraintLowerErr == nil {
		var validationErr error
		validatedPolicy, validationErr = validateToolConstraintPolicy(constraintBody)
		if validationErr != nil {
			s.recordToolConstraintMetric(validatedPolicy.mode, "compile_rejection")
			writeToolConstraintValidationError(w, validationErr)
			return
		}
	} else if _, hasToolChoice := parsed["tool_choice"]; hasToolChoice || requestHasTools(parsed) {
		s.recordToolConstraintMetric(validatedPolicy.mode, "compile_rejection")
		writeJSON(w, http.StatusBadRequest, errorResponse(
			"invalid_request_error", constraintLowerErr.Error()))
		return
	}
	validatedMode := validatedPolicy.mode
	toolChoiceName := validatedPolicy.name
	parallelToolCalls := validatedPolicy.parallel
	s.recordToolConstraintMetric(validatedMode, "requested")
	requiresToolConstraint := validatedMode.requiresInferenceConstraint()
	requiresVision := detectMediaRequirement(parsed)
	hasTools := requestHasTools(parsed)
	aliasTraits := registry.RequestTraits{
		HasTools:               hasTools,
		RequiresToolConstraint: requiresToolConstraint,
		ToolChoiceMode:         string(validatedMode),
		ToolChoiceName:         toolChoiceName,
		ParallelToolCalls:      parallelToolCalls,
	}

	// Resolve a public alias to a concrete build id, constraint-aware (after
	// allowlist/self-route are known). resolveRequestedModel rewrites
	// parsed["model"] to the build; this handler builds the provider body fresh
	// from `parsed` (inferenceBody below), so rawBody isn't threaded here.
	buildModel, publicModel, _, ok := s.resolveRequestedModel(
		parsed, rawBody, model, allowedProviderSerials, policy, aliasTraits)
	if !ok {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "model_resolution",
			reasonCode:      "model_unavailable",
			httpStatus:      http.StatusServiceUnavailable,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), withParam("model")))
		return
	}
	model = buildModel

	if !policy.enabled && !s.registry.IsModelInCatalog(model) {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "model_resolution",
			reasonCode:      "model_not_found",
			httpStatus:      http.StatusNotFound,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  publicModel,
			resolvedModel:   model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), withParam("model")))
		return
	}
	// Shared media/tools fail-fast (see visionToolsFailFast). Completions and
	// Anthropic bodies share the top-level "tools" field; neither has the
	// Responses-API media surface, so rejectResponsesMedia is false here.
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		requiresToolConstraint, string(validatedMode),
		false, policy, allowedProviderSerials) {
		return
	}
	if s.rejectRemoteMediaURLs(w, r, parsed, model, publicModel, requiresVision, hasTools) {
		return
	}

	// Completions and Anthropic messages both use the max_tokens field (never
	// max_output_tokens, which is Responses API only). Inject a default if
	// unset so the pre-flight reservation bounds the generation.
	genericMaxOutput := defaultMaxOutputTokens
	modelMaxContext := 0
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		// Keep generic endpoints aligned with chat completions: parser defaults
		// are catalog-owned request semantics, not provider inference guesses.
		runtimeDefaults.apply(parsed, rec.RuntimeParameters)
		if rec.MaxOutputLength > 0 {
			genericMaxOutput = rec.MaxOutputLength
		}
		modelMaxContext = rec.MaxContextLength
	}
	ensureMaxTokensBound(parsed, false, genericMaxOutput)

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	genericDeadline := s.FirstContentDeadline(model, estimatedPromptTokens)
	timing.ParsedAt = time.Now()
	rp.Mark(registry.StampReqParsed)
	if s.shedIfModelRejected(w, r, parsed, policy, publicModel, model, stream, estimatedPromptTokens, requestedMaxTokens, requiresVision, hasTools) {
		return
	}

	// Bind the endpoint to the cache-planning input. Successful lowering removes
	// it from the final OpenAI chat body before that body is sealed.
	parsed["endpoint"] = endpoint

	// Per-account token rate limiting (ITPM/OTPM), before the reservation.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation + per-key spend cap (see
	// reserveInferenceBalance). Self-route and a nil billing backend are free.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)
	reservedMicroUSD, serviceReservation, reserveHandled := s.reserveInferenceBalance(w, r, parsed, balanceReservationParams{
		model:                 model,
		publicModel:           publicModel,
		billingPromptTokens:   billingPromptTokens,
		estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens:    requestedMaxTokens,
		stream:                stream,
		requiresVision:        requiresVision,
		hasTools:              hasTools,
		policy:                policy,
	})
	if reserveHandled {
		return
	}
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.releaseInitialReservation(consumerKey, model, reservedMicroUSD, serviceReservation)
		}
	}
	timing.ReservedAt = time.Now()
	rp.Mark(registry.StampReqReserved)

	lowerGenericBodyForModel := func(candidateModel string) ([]byte, []byte, error) {
		candidateParsed := make(map[string]any, len(parsed))
		for key, value := range parsed {
			candidateParsed[key] = value
		}
		candidateParsed["model"] = candidateModel
		candidateDefaults := runtimeDefaults
		if rec, err := s.store.GetModelRegistryRecord(candidateModel); err == nil {
			candidateDefaults.apply(candidateParsed, rec.RuntimeParameters)
		} else {
			candidateDefaults.apply(candidateParsed, nil)
		}
		endpointBody, _ := marshalForwardBody(candidateParsed)
		inferenceBody, loweringErr := promptcontract.LowerProviderBody(
			endpointKind, endpointBody)
		if loweringErr != nil {
			inferenceBody = endpointBody
		}
		return endpointBody, inferenceBody, loweringErr
	}
	routingTraitsForModel := func(candidateModel string) registry.RequestTraits {
		_, candidateBody, _ := lowerGenericBodyForModel(candidateModel)
		traits, _ := routingTraitsForProviderBody(
			hasTools, candidateBody, requiresVision)
		traits.RequiresToolConstraint = requiresToolConstraint
		traits.ToolChoiceMode = string(validatedMode)
		traits.ToolChoiceName = toolChoiceName
		traits.ParallelToolCalls = parallelToolCalls
		return traits
	}
	providerBodyErrorForModel := func(candidateModel string) error {
		_, candidateBody, _ := lowerGenericBodyForModel(candidateModel)
		_, sizeErr := routingTraitsForProviderBody(
			hasTools, candidateBody, requiresVision)
		return sizeErr
	}
	var endpointBody, inferenceBody []byte
	var loweringErr error
	routingTraits := routingTraitsForModel(model)
	refreshGenericBody := func(newModel string) bool {
		var runtimeParameters map[string]any
		if rec, err := s.store.GetModelRegistryRecord(newModel); err == nil {
			runtimeParameters = rec.RuntimeParameters
			runtimeDefaults.apply(parsed, runtimeParameters)
		} else {
			runtimeDefaults.apply(parsed, nil)
		}
		if err := validateResolvedToolConstraintParser(
			parsed, validatedMode, newModel, s.registry.ModelType(newModel),
			runtimeParameters,
		); err != nil {
			s.recordToolConstraintMetric(validatedMode, "compile_rejection")
			writeToolConstraintValidationError(w, err)
			refundReservation()
			return false
		}
		endpointBody, inferenceBody, loweringErr = lowerGenericBodyForModel(newModel)
		routingTraits, _ = routingTraitsForProviderBody(
			hasTools, inferenceBody, requiresVision)
		routingTraits.RequiresToolConstraint = requiresToolConstraint
		routingTraits.ToolChoiceMode = string(validatedMode)
		routingTraits.ToolChoiceName = toolChoiceName
		routingTraits.ParallelToolCalls = parallelToolCalls
		return true
	}
	if !refreshGenericBody(model) {
		return
	}

	// Shared routing/capacity admission preflight (self-route / prefer / public
	// capacity+TTFT gate — see runInferenceAdmission).
	var preflightHandled bool
	preflightStart := time.Now()
	model, preflightHandled = s.runInferenceAdmission(w, r, parsed, inferenceAdmissionParams{
		model:                     model,
		publicModel:               publicModel,
		stream:                    stream,
		estimatedPromptTokens:     estimatedPromptTokens,
		requestedMaxTokens:        requestedMaxTokens,
		requiresVision:            requiresVision,
		hasTools:                  hasTools,
		traits:                    &routingTraits,
		traitsForModel:            routingTraitsForModel,
		providerBodyErrorForModel: providerBodyErrorForModel,
		modelMaxContext:           modelMaxContext,
		allowedProviderSerials:    allowedProviderSerials,
		deadline:                  genericDeadline,
		policy:                    policy,
		refundReservation:         refundReservation,
		onModelFallback:           refreshGenericBody,
	})
	if rp != nil {
		rp.PreflightUS = time.Since(preflightStart).Microseconds()
		rp.Mark(registry.StampReqPreflightDone)
		if preflightHandled {
			rp.PreflightOutcome = "handled"
		} else {
			rp.PreflightOutcome = "passed"
		}
	}
	if preflightHandled {
		return
	}
	cachePlan := registry.CachePlan{}
	// Response framing is determined by the caller-facing endpoint, never by
	// whether its request shape could be lowered for cache participation.
	consumerEndpoint, requestedStopSequences := genericResponseMetadata(endpoint, parsed)
	if loweringErr == nil {
		cachePlan = s.planCacheRoute(
			r.Context(), consumerKey, model, inferenceBody, requiresVision)
	} else {
		// Endpoint lowering is a cache-routing eligibility boundary, not a new
		// inference rejection. Preserve the existing generic endpoint behavior
		// for unsupported shapes while declining cache participation.
		inferenceBody = endpointBody
	}

	// Generic endpoints use the same dispatch state machine as chat. This keeps
	// queue deadlines, speculative failover, pre-content boilerplate handling,
	// typed deadline refusals, and terminal 429 semantics identical.
	genericRegistryReadStart := time.Now()
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		modelMaxContext = rec.MaxContextLength
	}
	profileDBCall(rp, genericRegistryReadStart)
	rp.Mark(registry.StampReqPlanDone)
	if rp != nil {
		rp.Model, rp.PublicModel, rp.Stream = model, publicModel, stream
		rp.FirstContentBudgetMs = int(genericDeadline.Milliseconds())
		rp.EstimatedPromptTokens, rp.RequestedMaxTokens = estimatedPromptTokens, requestedMaxTokens
		rp.RequiresVision, rp.HasTools = requiresVision, hasTools
		rp.BodyBytes = len(rawBody)
	}
	d := &dispatchState{
		s:                      s,
		w:                      w,
		r:                      r,
		model:                  model,
		publicModel:            publicModel,
		rawBody:                inferenceBody,
		consumerKey:            consumerKey,
		consumerLocation:       consumerLocation,
		reservedMicroUSD:       reservedMicroUSD,
		tokenAdmission:         tokenAdmission,
		serviceReservation:     serviceReservation,
		estimatedPromptTokens:  estimatedPromptTokens,
		requestedMaxTokens:     requestedMaxTokens,
		requiresVision:         requiresVision,
		visionImageCount:       countMediaParts(parsed),
		hasTools:               hasTools,
		requiresToolConstraint: requiresToolConstraint,
		toolChoiceMode:         string(validatedMode),
		toolChoiceName:         toolChoiceName,
		parallelToolCalls:      parallelToolCalls,
		consumerEndpoint:       consumerEndpoint,
		requestedStopSequences: requestedStopSequences,
		stream:                 stream,
		metadataDetails:        metadataDetailsFromRequest(r),
		policy:                 policy,
		allowedProviderSerials: allowedProviderSerials,
		cachePlan:              cachePlan,
		timing:                 timing,
		profile:                rp,
		deadline:               genericDeadline,
		speculativeAt:          time.Duration(float64(genericDeadline) * speculativeTimerRatio),
		modelMaxContext:        modelMaxContext,
		refundReservation:      refundReservation,
		excludeProviders:       make(map[string]struct{}),
	}
	d.run()
}
