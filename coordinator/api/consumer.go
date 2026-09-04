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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"

	"github.com/eigeninference/d-inference/coordinator/api/types"
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
	// to a retryable 429 with reason "first_chunk_timeout") — a BACKSTOP for
	// the relative-timer configuration only. With a stamped request clock
	// (RequestTiming.ReceivedAt set, i.e. every production request) each
	// timeout arm fires at the request-absolute first-content expiry
	// (deadlineWait = the leftover absolute budget, first_token_clock.go) and
	// the next loop iteration exhausts on `attempt > 0 && firstTokenExpired()`
	// before any rescan, so a stamped request dispatches ONCE and then answers
	// the 429: this cap never operates there. It binds only when ReceivedAt is
	// unstamped (unit fixtures, historical relative timers), where every
	// attempt would otherwise get its own fresh window and the ladder could
	// walk the fleet one reservation scan per silent provider — the CPU
	// amplification of the 2026-09-01 collapse (retry-amplified inbound times
	// per-request fleet scans). Timed-out providers stay excluded from
	// re-selection either way.
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

var thinkBlockPattern = regexp.MustCompile(`(?is)<think>(.*?)</think>\s*`)

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
	// The shed floor is a caller floor under the shared Retry-After source
	// (retry_after.go): a rejected model stays out of rotation for at least
	// 30 s, jittered like every other capacity rejection so the return herd is
	// spread. (The former `retryAfter <= 0 → 30` fallback was dead code — the
	// queue-depth estimate never returned < 2 — so a shed model answered 2 s.)
	retryAfter := s.retryAfterSeconds(model, retryAfterJitterKey(r.Context()),
		s.registry.Queue().QueueSize(model), modelShedRetryAfterFloorSeconds)
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
// provider and reports whether the frame was handed to the provider writer
// (directly, or through the bounded blocking fallback below). The fast path
// is a non-blocking enqueue on the writer's control lane. Every failure of
// that enqueue is metered (inference.cancel_send_failed{reason}) — a dropped
// cancel is the only silent-loss path on the coordinator side of cancel
// delivery — and a writer that is already gone is logged at debug level
// because a disconnect race is the expected case. A FULL control lane takes
// the bounded blocking fallback instead of dropping the cancel.
//
// This is the raw primitive. Abandon paths that may leave the provider
// generating go through sendAbandonCancel / cancelDispatch so the cancel is
// recorded for terminal correlation and zombie re-sends.
func (s *Server) sendProviderCancel(provider *registry.Provider, requestID string) bool {
	if provider == nil || provider.Conn == nil {
		return false
	}
	if len(requestID) > maxCancelRequestIDLen {
		s.ddIncr("provider.cancel_dropped", []string{"reason:oversized_id"})
		return false
	}
	cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: requestID}
	cancelData, err := json.Marshal(cancelMsg)
	if err != nil {
		s.logger.Error("failed to marshal cancel message", "request_id", requestID, "error", err)
		return false
	}
	// EnqueueText never blocks and never waits on ctx (the writer only reads
	// ctx.Err() at accept), so there is nothing for a timeout to bound here.
	err = provider.EnqueueText(context.Background(), cancelData)
	if err == nil {
		return true
	}
	s.ddIncr(metricCancelSendFailed, []string{"reason:" + cancelSendFailureReason(err)})
	if !errors.Is(err, registry.ErrProviderWriterQueueFull) {
		s.logger.Debug("failed to send cancel (provider may have disconnected)",
			"request_id", requestID, "error", err)
		return false
	}
	// The control lane is full: the writer is wedged behind a slow data write
	// and providerControlQueueSize control frames are already waiting.
	// Dropping the cancel here (the old behavior) left the provider decoding
	// into a stream nobody reads, burning GPU and token-budget admission until
	// the generation ran out on its own. Retry with a bounded wait, off the
	// caller's goroutine so neither an HTTP handler nor the provider read loop
	// stalls behind it.
	//
	// Bounded per connection: a provider that stops draining while emitting
	// chunks for unique unknown request IDs would otherwise park one goroutine
	// per cancel for the fallback timeout each. Past the cap the cancel is
	// dropped and counted; the provider is misbehaving in that case anyway.
	if !provider.TryAcquireControlFallback() {
		s.ddIncr("provider.cancel_dropped", []string{"reason:fallback_cap"})
		return false
	}
	saferun.Go(s.logger, "provider.cancelFallback", func() {
		defer provider.ReleaseControlFallback()
		ctx, cancel := context.WithTimeout(context.Background(), cancelWriteTimeout)
		defer cancel()
		if _, err := provider.EnqueueControlOrWait(ctx, cancelData); err != nil {
			s.ddIncr("provider.cancel_dropped", []string{"reason:fallback_timeout"})
			s.logger.Warn("cancel dropped after control-lane fallback",
				"request_id", requestID, "error", err)
		}
	})
	return true
}

// maxCancelRequestIDLen bounds the request_id echoed back in a cancel. Real
// request IDs are UUIDs; a provider-controlled unknown-request ID (the zombie
// path) must not be able to turn every cancel into an oversized frame.
const maxCancelRequestIDLen = 256

func writeProviderInferenceRequestDeferred(
	ctx context.Context,
	provider *registry.Provider,
	builder registry.TextFrameBuilder,
	onHandoff registry.TextFrameHandoff,
) (registry.TextFrameWriteMetadata, error) {
	if provider == nil || provider.Conn == nil {
		// Same class as a dead writer (the socket is gone), so the send-failed
		// ladder tags it writer_stopped.
		return registry.TextFrameWriteMetadata{}, fmt.Errorf("provider websocket is not connected: %w", registry.ErrProviderWriterStopped)
	}
	return provider.WriteTextDeferred(ctx, builder, onHandoff)
}

// cancelDispatch abandons a dispatch attempt that may still be generating
// (hedge loser, client gone before content): removes the pending request,
// sends a cancel over WebSocket so the provider stops, marks the provider
// idle, and refunds this attempt's provider-specific reservation top-up.
// cause is the bounded cancel cause recorded for terminal correlation.
//
// Order matters: the cancel is enqueued BEFORE SetProviderIdle. SetProviderIdle
// drains the model queue synchronously (one reservation scan per queued
// waiter) and may hand the freed slot to a new request, so the stop must
// already be on the provider's control lane when that happens instead of
// reaching the wire after a full drain pass.
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
	if removed != nil && !pr.HasCompletionIngress() {
		s.sendRecordedCancel(provider, pr, cause, now)
	} else if created {
		s.zombieCanceller.forget(pr.RequestID)
	}
	s.registry.SetProviderIdle(provider.ID)
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
	// Cancel before the idle drain, as in cancelDispatch.
	s.sendRecordedCancel(provider, pr, cancelCauseFirstChunkTimeout, now)
	s.registry.SetProviderIdle(provider.ID)
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
func (s *Server) noteInferenceError(providerID string, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string) {
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
	if s.registry.RecordInferenceError(providerID, pr.Model, statusCode, pr.Traits.CooldownShape()) {
		s.ddIncr("routing.cooldown_entered", []string{"model:" + pr.Model})
	}
	// Feed EVERY provider terminal into the per-provider node-health breaker (not
	// just the shape-keyed 5xx the inference-error breaker counts) so a node
	// fault-503ing ~all of its requests gets quarantined fleet-wide. errStr lets
	// the breaker tell a capacity-503 (ignored) from a fault-503 (counted). Both
	// breakers coexist.
	if opened, _ := s.registry.RecordProviderOutcome(providerID, false, statusCode, errStr); opened {
		s.ddIncr("routing.provider_breaker_open", []string{"model:" + pr.Model})
	}
	// Feed the STABLE-IDENTITY ejection breaker too (survives reconnect churn, so a
	// zombie that fault-loops while constantly disconnecting still accumulates).
	if sid := s.registry.GetProviderStableIdentity(providerID); sid != "" {
		if ejected, _ := s.registry.RecordProviderServeOutcome(sid, false, statusCode, errStr); ejected {
			s.ddIncr("routing.provider_ejected", []string{"model:" + pr.Model})
		}
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
func (s *Server) noteDispatchProviderError(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, held *[]string) (discardedHeld bool) {
	if provider != nil {
		s.noteInferenceError(provider.ID, pr, statusCode, errStr, errReason, terminalCause)
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

// estimateTTFTRetryAfter is retryAfterSeconds with the TTFT overage (how far
// the best estimate sits above the target, in whole seconds) as the caller
// floor, so the answer is never shorter than the gap that has to close. It
// no longer re-clamps to its own [2,30] band (which also capped the distress
// term at 30 on this path). requestID is the jitter key.
func (s *Server) estimateTTFTRetryAfter(model, requestID string, bestTTFT, threshold time.Duration) int {
	overage := int(math.Ceil((bestTTFT - threshold).Seconds()))
	return s.retryAfterSeconds(model, requestID, s.registry.Queue().QueueSize(model), overage)
}

// writeFirstTokenTimeout writes the OpenRouter-compatible retryable 429 used
// when a request-absolute first-token clock expires after dispatch. Chat
// exhausted already uses this shape (Retry-After + rate_limit_exceeded);
// /v1/completions and /v1/messages must match so aggregators retry instead
// of treating the timeout as a provider 504. requestID is the jitter key.
func (s *Server) writeFirstTokenTimeout(w http.ResponseWriter, requestID, model, message string) {
	retryAfter := s.retryAfterSeconds(model, requestID, s.registry.Queue().QueueSize(model), 0)
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
		message, withCode("rate_limit_exceeded")))
}

func (s *Server) writeTTFTTooSlow(w http.ResponseWriter, requestID, model, publicModel string, bestTTFT, threshold time.Duration) {
	retryAfter := s.estimateTTFTRetryAfter(model, requestID, bestTTFT, threshold)
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
	expectedCompletionTokens int,
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
		requestedMaxTokens, expectedCompletionTokens, tokenAdmission, requiresVision, traits,
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
	expectedCompletionTokens int,
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
		Attempt:               attempt,
		Model:                 model,
		PublicModel:           publicModel,
		ConsumerKey:           consumerKey,
		KeyID:                 keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:      keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:         keyLimitResetFromContext(r.Context()),
		ConsumerLocation:      consumerLocation,
		IsResponsesAPI:        isResponsesAPI,
		EstimatedPromptTokens: estimatedPromptTokens,
		RequiresVision:        requiresVision,
		Traits:                traits,
		RequestedMaxTokens:    requestedMaxTokens,
		// Routing-only expected completion; 0 = unset → RequestedMaxTokens.
		ExpectedCompletionTokens: expectedCompletionTokens,
		TokenAdmission:           tokenAdmission,
		CachePlan:                cachePlan,
		ReservedMicroUSD:         reservedMicroUSD,
		BaseReservedMicroUSD:     reservedMicroUSD,
		ServiceReservation:       serviceReservation,
		AllowedProviderSerials:   allowedProviderSerials,
		SelfRouteOnly:            policy.enabled,
		PreferOwner:              policy.prefer,
		OwnerAccountID:           policy.ownerAccountID,
		FreeSelfRoute:            policy.enabled,
		MetadataDetails:          metadataDetailsFromRequest(r),
		AcceptedCh:               make(chan struct{}, 1),
		ChunkCh:                  make(chan registry.ProviderChunk, chunkBufferSize),
		CompleteCh:               make(chan protocol.UsageInfo, 1),
		ErrorCh:                  make(chan protocol.InferenceErrorMessage, 1),
		Timing:                   timing,
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
	s.emitReserveDecisionMetrics(model, decision)
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
	writeMetadata, writeErr := writeProviderInferenceRequestDeferred(
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
		// A frame the writer already handed off completes on the wire even
		// though this attempt is abandoned (request clock or client hang-up
		// mid-write): cancel it, and do so BEFORE cleanupPending's idle drain
		// so the stop is on the control lane ahead of any new assignment. A
		// frame discarded before handoff gets no cancel.
		s.cancelAbortedProviderWrite(provider, pr, writeMetadata, writeErr)
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		if errors.Is(writeErr, context.DeadlineExceeded) ||
			errors.Is(writeErr, errFirstContentDeadlineAtWriter) {
			return nil, nil, decision, plan, errFirstContentDeadlineExpired, http.StatusGatewayTimeout
		}
		// Status 0, not 502: no provider ran the request, so the exhausted
		// ladder classifies this class itself (rejectionReasonProviderUnreachable).
		s.ddIncr("routing.dispatch_to_capacity_503", []string{
			"model:" + pr.Model, "reason:send_failed", "kind:" + providerSendFailureKind(writeErr)})
		return nil, nil, decision, plan, errProviderSendFailedText, 0
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

func exhaustedProviderPreparationError(
	decision registry.RoutingDecision,
	reservationErr error,
	providerBodyOverflowErr error,
) error {
	if decision.CapacityRejections > 0 {
		return nil
	}
	if reservationErr != nil {
		return reservationErr
	}
	return providerBodyOverflowErr
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

// estimateRetryAfter returns the PRE-JITTER Retry-After base for a model at
// its current queue depth with no caller floor (retry_after.go): the fleet
// capacity estimate from the warm-pool snapshot when one exists, else the
// legacy queue-depth heuristic, max'ed with the #799 distress floor
// (distressFloorSeconds: when the attempt-0 route-latency EWMA shows routing
// itself is degraded (> 1 s) the answer scales with the observed degradation
// — ceil(EWMA seconds) × 5, capped at 60 s — so upstream backoff actually
// relieves pressure). No response writer calls this directly: writers go
// through retryAfterSeconds, which adds the per-request jitter.
func (s *Server) estimateRetryAfter(model string) int {
	return s.retryAfterBaseSeconds(model, s.registry.Queue().QueueSize(model), 0)
}

// writeServiceUnavailable writes a retryable 503 with a Retry-After header so
// clients (and OpenRouter) can schedule the retry instead of blind backoff.
func (s *Server) writeServiceUnavailable(w http.ResponseWriter, r *http.Request, model string) {
	w.Header().Set("Retry-After", strconv.Itoa(s.retryAfterSeconds(model, retryAfterJitterKey(r.Context()),
		s.registry.Queue().QueueSize(model), 0)))
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
	// ReceivedAt is the HTTP ingress instant, not handler entry: the
	// first-content clock (and the media-fetch budget derived from it) must
	// not silently gain the pre-handler auth/rate-limit/decrypt time.
	timing := &registry.RequestTiming{ReceivedAt: ingressStartFromContext(r.Context())}
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
	// Captured BEFORE the bound is injected: the routing decode term keys off
	// whether the client bounded the generation itself (routing_estimates.go).
	clientSetMaxTokens := explicitMaxTokens(parsed) > 0
	if ensureMaxTokensBound(parsed, isResponsesAPI, maxOutputBound) {
		body.markDirty()
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := shape.routingPromptTokens(parsed)
	billingPromptTokens := shape.billingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	expectedCompletionTokens := s.expectedCompletionTokensForRouting(model, parsed, clientSetMaxTokens, requestedMaxTokens)
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
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens, publicModel)
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
		// Nothing was generated: return the upfront OTPM charge (once).
		s.creditUnusedOutputAdmission(consumerKeyFromContext(r.Context()), keyIDFromContext(r.Context()), tokenAdmission)
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
	admissionModel := model
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
	if model != admissionModel {
		// Alias fallback (maybeFallbackAlias) rewrote the concrete build; the
		// learned completion length is keyed by build id, so re-derive it.
		expectedCompletionTokens = s.expectedCompletionTokensForRouting(model, parsed, clientSetMaxTokens, requestedMaxTokens)
		// The first-content base is keyed by exact build id too (Qwen3-VL runs a
		// 4 s base under the ordinary 9 s), so a fallback across builds must
		// re-derive the clock the dispatch state, the queue wait and
		// rp.FirstContentBudgetMs run on; the request-absolute anchor
		// (ReceivedAt) is unchanged.
		deadline = s.FirstContentDeadline(model, estimatedPromptTokens)
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
		// Routing-only decode length for the scheduler's cost term (routing_estimates.go).
		expectedCompletionTokens: expectedCompletionTokens,
	}
	d.run()
}

// handleStreamingResponseWithFirstChunk streams SSE chunks to the consumer.
// Any firstChunks (held preamble + first content chunk) are written in order
// before reading further chunks from the channel. This allows the dispatch
// loop to "peek" at chunks for retry decisions without losing them.
func (s *Server) handleStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	s.handleStreamingResponseWithFirstChunkAndError(w, r, pr, firstChunks, nil)
}

func (s *Server) handleStreamingResponseWithFirstChunkAndError(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	if pr.ConsumerEndpoint == completionsEndpoint || pr.ConsumerEndpoint == messagesEndpoint {
		s.handleGenericEndpointStreamingResponseWithError(
			w, r, pr, firstChunks, initialError)
		return
	}
	if pr.IsResponsesAPI {
		s.handleResponsesStreamingResponseWithFirstChunk(
			w, r, pr, firstChunks, initialError)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	writeSSEResponseHeader(w, pr.RequestID)
	flusher.Flush()
	rs := newRelayStamps(pr.Profile.Parent())

	// Per-request relay state: the Responses-format latch, the held terminal
	// usage/finish frames, and the batch buffer. Every chunk — the ones already
	// consumed during dispatch and the ones relayed below — goes through the
	// same relay.handleChunk pipeline (see chat_stream_relay.go).
	relay := newChatStreamRelay(pr)

	// Write the chunks that were already consumed during dispatch (held
	// preamble first, then the committing content chunk).
	for _, firstChunk := range firstChunks {
		if firstChunk == "" {
			continue
		}
		relay.handleChunk(firstChunk)
	}
	rs.wroteFrames(relay.flush(w, flusher))
	if initialError != nil {
		s.writeChatStreamProviderError(w, flusher, pr, *initialError)
		return
	}

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	// finishStream runs once ChunkCh is observed closed — on the blocking
	// receive or while draining already-queued chunks (after those were
	// flushed): surface a trailing provider error, refund an incomplete stream,
	// or emit the held finish/usage frames and the single [DONE].
	finishStream := func() {
		select {
		case errMsg, ok := <-pr.ErrorCh:
			if ok && errMsg.Error != "" {
				s.writeChatStreamProviderError(w, flusher, pr, errMsg)
				return
			}
		default:
		}
		if s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
			s.writeChatStreamTerminalError(
				w, flusher, pr, "provider_error", "provider ended without completion")
			return
		}
		// Channel closed — inference complete.
		s.noteInferenceSuccess(pr)
		// For Responses API streams, the provider already sent
		// "response.completed" as the terminal event. Adding
		// extra chunks would break SDK parsers.
		if relay.sawResponsesAPI {
			return
		}
		// Emit the held finish/usage chunks with the authoritative token
		// counts (CompleteCh) spliced in: the finish chunk gets its
		// finish_reason corrected to "length" when generation hit the
		// max-tokens bound, and the usage chunk gets the reasoning
		// breakdown. This select runs once, at stream end: the provider's
		// inferenceComplete (which populates CompleteCh) is what ends the
		// stream, so it is effectively already buffered — the timeout is a
		// fallback, not a hot-path wait.
		var usage protocol.UsageInfo
		if relay.pendingUsage != nil || relay.pendingFinish != nil {
			select {
			case u, uok := <-pr.CompleteCh:
				if uok {
					usage = u
				}
			case <-time.After(2 * time.Second):
			case <-r.Context().Done():
			}
		}
		if relay.pendingFinish != nil {
			if out := finalizeFinishChunk(relay.pendingFinish, usage, pr); out != "" {
				relay.writeFrame(out)
			}
		}
		if relay.pendingUsage != nil {
			// Ride the SE signature on the held usage chunk (a complete,
			// well-formed chat.completion.chunk) instead of emitting a
			// separate bare event that strict SDK parsers reject.
			if pr.SESignature != "" {
				relay.pendingUsage["se_signature"] = pr.SESignature
				relay.pendingUsage["response_hash"] = pr.ResponseHash
			}
			attachChatCompletionMetadata(relay.pendingUsage, pr)
			if out := finalizeUsageChunk(relay.pendingUsage, usage, pr); out != "" {
				relay.writeFrame(out)
			}
		} else if pr.SESignature != "" || hasChatCompletionMetadata(pr) {
			// No held usage chunk to ride on: emit the signature and/or
			// opt-in metadata as a fully-shaped chat.completion.chunk
			// (id/object/created/model/choices) so strict decoders parse
			// it; the extra fields are additive. It precedes the single
			// [DONE] below.
			event := newChatCompletionExtrasEvent(pr)
			if pr.SESignature != "" {
				event["se_signature"] = pr.SESignature
				event["response_hash"] = pr.ResponseHash
			}
			attachChatCompletionMetadata(event, pr)
			sigEvent, _ := json.Marshal(event)
			relay.writeFrame("data: " + string(sigEvent))
		}
		// Exactly one terminator, after every coordinator-appended event. The
		// terminal frames reach the wire together in one flush.
		relay.writeFrame("data: [DONE]")
		rs.wroteFrames(relay.flush(w, flusher))
		rs.done()
	}

	// relayChunk forwards one provider chunk. Every chunk is a liveness
	// signal — re-arm the idle timeout up front, before deciding whether to
	// forward or hold it, so holding the terminal usage chunk still resets
	// the window that bounds the wait for the provider's inference_complete
	// (which closes ChunkCh after billing).
	relayChunk := func(chunk registry.ProviderChunk) {
		resetIdleTimer(timer, inferenceTimeout)
		relay.handleChunk(chunk.Data)
	}

	for {
		select {
		case providerChunk, ok := <-pr.ChunkCh:
			if !ok {
				finishStream()
				return
			}
			relayChunk(providerChunk)
			// Fold in whatever the provider already queued behind this chunk
			// (never waiting for more), then flush the batch once. A close
			// observed mid-drain is handled exactly like the blocking-receive
			// close — after the drained chunks are on the wire.
			closed := drainQueuedChunks(pr.ChunkCh, maxCoalescedChunks-1, relayChunk)
			rs.wroteFrames(relay.flush(w, flusher))
			if closed {
				finishStream()
				return
			}

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			// The provider error is delivered before ChunkCh is closed, so
			// chunks that arrived ahead of it may still be queued: forward them
			// (never waiting) before the terminal error so a late failure never
			// truncates content the provider already produced.
			drainQueuedChunks(pr.ChunkCh, cap(pr.ChunkCh), relayChunk)
			rs.wroteFrames(relay.flush(w, flusher))
			s.writeChatStreamProviderError(w, flusher, pr, errMsg)
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
			s.writeChatStreamTerminalError(w, flusher, pr, "timeout", "request timed out")
			return

		case <-r.Context().Done():
			profileClientGone(pr, phaseAfterCommit)
			return
		}
	}
}

func (s *Server) writeChatStreamProviderError(
	w http.ResponseWriter,
	flusher http.Flusher,
	pr *registry.PendingRequest,
	errMsg protocol.InferenceErrorMessage,
) {
	s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
	s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause)
	s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
	s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
	s.writeChatStreamTerminalError(
		w, flusher, pr, "provider_error", clientSafeInferenceErrorMessage(errMsg))
}

func (s *Server) handleResponsesStreamingResponseWithFirstChunk(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	writeSSEResponseHeader(w, pr.RequestID)

	// The emitter flushes after every event; defer those flushes so a burst of
	// already-queued provider chunks reaches the wire in one Flush. Every
	// return path performs the owed flush.
	deferred := newDeferredFlusher(flusher)
	defer deferred.flushNow()

	responseID := "resp_" + strings.ReplaceAll(pr.RequestID, "-", "")
	createdAt := time.Now().Unix()
	emitter := newResponsesStreamEmitter(w, deferred, pr, responseID, createdAt)
	emitter.start()

	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			emitter.handleChunk(sanitizeStreamCacheDetails(firstChunk))
		}
	}
	if initialError != nil {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, *initialError))
		emitter.emitError("provider_error", clientSafeInferenceErrorMessage(*initialError))
		return
	}
	// The preamble (lifecycle events + dispatch-time chunks) goes on the wire
	// before blocking on the provider.
	deferred.flushNow()

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	// emitProviderError settles and reports an in-band provider error.
	emitProviderError := func(errMsg protocol.InferenceErrorMessage) {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause)
		s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
		s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
		emitter.emitError("provider_error", clientSafeInferenceErrorMessage(errMsg))
	}

	// finishStream runs once ChunkCh is observed closed — on the blocking
	// receive or while draining already-queued chunks (after those were
	// flushed). A provider error is delivered on ErrorCh just before the
	// channels close, so it is checked first: a close must never turn a real
	// provider error into "incomplete" (or, with nothing reserved, success).
	finishStream := func() {
		select {
		case errMsg, ok := <-pr.ErrorCh:
			if ok && errMsg.Error != "" {
				emitProviderError(errMsg)
				return
			}
		default:
		}
		var usage protocol.UsageInfo
		completed := false
		select {
		case u, ok := <-pr.CompleteCh:
			if ok {
				usage = u
				completed = true
			}
		case <-time.After(2 * time.Second):
		}
		if !completed && s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
			emitter.emitError("provider_error", "provider ended without completion")
			return
		}
		s.noteInferenceSuccess(pr)
		emitter.finish(usage)
	}

	relayChunk := func(chunk registry.ProviderChunk) {
		emitter.handleChunk(sanitizeStreamCacheDetails(chunk.Data))
		resetIdleTimer(timer, inferenceTimeout)
	}

	for {
		select {
		case providerChunk, ok := <-pr.ChunkCh:
			if !ok {
				finishStream()
				return
			}
			relayChunk(providerChunk)
			// Fold in whatever the provider already queued behind this chunk
			// (never waiting for more), then flush the batch once. A close
			// observed mid-drain is handled exactly like the blocking-receive
			// close — after the drained chunks are on the wire.
			closed := drainQueuedChunks(pr.ChunkCh, maxCoalescedChunks-1, relayChunk)
			deferred.flushNow()
			if closed {
				finishStream()
				return
			}

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			// Forward chunks queued ahead of the error before the terminal
			// event (see the chat relay for the rationale).
			drainQueuedChunks(pr.ChunkCh, cap(pr.ChunkCh), relayChunk)
			deferred.flushNow()
			emitProviderError(errMsg)
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
			emitter.emitError("timeout", "request timed out")
			return

		case <-r.Context().Done():
			profileClientGone(pr, phaseAfterCommit)
			return
		}
	}
}

// handleNonStreamingResponseWithFirstChunk collects all chunks from the
// provider and assembles them into a single OpenAI-compatible JSON response.
// Any firstChunks (held preamble + first content chunk consumed during
// dispatch) seed the collected chunks in order.
func (s *Server) handleNonStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	s.handleNonStreamingResponseWithFirstChunkAndError(w, r, pr, firstChunks, nil)
}

func (s *Server) handleNonStreamingResponseWithFirstChunkAndError(
	w http.ResponseWriter,
	r *http.Request,
	pr *registry.PendingRequest,
	firstChunks []string,
	initialError *protocol.InferenceErrorMessage,
) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string
	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			chunks = append(chunks, firstChunk)
		}
	}
	if initialError != nil {
		s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
		s.noteInferenceError(pr.ProviderID, pr, initialError.StatusCode, initialError.Error, initialError.ErrorReason, initialError.TerminalCause)
		s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, *initialError))
		s.writeGenericProviderError(w, *initialError)
		return
	}

	for {
		select {
		case providerChunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause)
						s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, errMsg))
						s.writeGenericProviderError(w, errMsg)
						return
					}
				default:
				}
				// The provider forwards the raw backend response as a single
				// chunk. Detect complete responses (object=chat.completion
				// or object=response) and pass through directly — this is
				// format-agnostic and works for chat completions, Responses
				// API, or any future endpoint without parsing.
				if len(chunks) == 1 {
					raw := strings.TrimPrefix(chunks[0], "data: ")
					var obj map[string]any
					if err := json.Unmarshal([]byte(raw), &obj); err == nil {
						objType, _ := obj["object"].(string)
						// Complete responses have object=chat.completion or
						// object=response. Delta chunks have object=chat.completion.chunk.
						if objType == "chat.completion" || objType == "response" {
							var completeUsage protocol.UsageInfo
							select {
							case u, ok := <-pr.CompleteCh:
								if !ok {
									s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
									s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderIncompleteOutcome(pr))
									writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
									return
								}
								completeUsage = u
							case <-ctx.Done():
								if errors.Is(ctx.Err(), context.DeadlineExceeded) {
									s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
									s.updateInferenceRouteOutcomeForPending(pr, preResponseTimeoutOutcome(pr, "usage_timeout_before_response"))
									writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
								} else {
									s.refundReservedBalance(pr, "client_gone:"+pr.RequestID)
									s.updateInferenceRouteOutcomeForPending(pr, clientGoneBeforeResponseOutcome(pr))
								}
								return
							}
							if objType == "chat.completion" {
								normalizeCompleteChatResponse(obj, consumerModel(pr))
								// The provider engine reports "stop" even when generation
								// hit the max-tokens bound — correct it from the
								// authoritative token counts.
								rewriteRawFinishReason(obj, completeUsage, pr.RequestedMaxTokens)
								// Keep the passthrough path consistent with the
								// SSE-reconstruction path: surface the provider's
								// accurate reasoning-token count if its raw usage
								// object didn't already carry one.
								injectReasoningDetailIntoRawUsage(obj, completeUsage)
								injectCacheDetailIntoRawUsage(obj, completeUsage)
								if pr.ConsumerEndpoint == completionsEndpoint ||
									pr.ConsumerEndpoint == messagesEndpoint {
									encoded, err := json.Marshal(obj)
									if err != nil {
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									msg := extractMessage([]string{"data: " + string(encoded)})
									resp := buildGenericEndpointResponse(pr, msg, completeUsage)
									s.noteInferenceSuccess(pr)
									writeNonStreamBody(w, pr.Profile.Parent(), resp)
									return
								}
								if pr.IsResponsesAPI {
									var chatResp types.ChatCompletionResponse
									b, err := json.Marshal(obj)
									if err != nil {
										log.Printf("WARN: failed to marshal chat response for Responses API conversion: %v", err)
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									if err := json.Unmarshal(b, &chatResp); err != nil {
										log.Printf("WARN: failed to unmarshal chat response into typed struct: %v", err)
										writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "invalid provider response"))
										return
									}
									respObj := chatCompletionToResponses(
										chatResp, consumerModel(pr), pr.SESignature,
										pr.ResponseHash, pr.Traits)
									s.noteInferenceSuccess(pr)
									writeNonStreamBody(w, pr.Profile.Parent(), respObj)
									return
								}
							} else {
								// Native passthrough (object=="response"): the provider
								// echoed the concrete build id; rewrite it to the public
								// alias so the consumer never sees the quant/build.
								sanitizeCacheDetailIntoRawResponsesUsage(obj, completeUsage)
								if pr.PublicModel != "" {
									obj["model"] = consumerModel(pr)
								}
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
							if isChatCompletionsConsumer(pr) {
								attachChatCompletionMetadata(obj, pr)
							}
							s.noteInferenceSuccess(pr)
							writeNonStreamBody(w, pr.Profile.Parent(), obj)
							return
						}
					}
				}

				// Only reconstructed chat-completions use provider-canonical
				// reasoning_content precedence. Responses and generic endpoints keep
				// the historical reasoning-first extraction contract.
				preferReasoningContent := !pr.IsResponsesAPI &&
					pr.ConsumerEndpoint != completionsEndpoint &&
					pr.ConsumerEndpoint != messagesEndpoint
				msg := extractMessageWithReasoningPolicy(chunks, preferReasoningContent)
				select {
				case usage, ok := <-pr.CompleteCh:
					if !ok {
						s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID)
						s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderIncompleteOutcome(pr))
						writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
						return
					}
					var resp any
					if pr.IsResponsesAPI {
						resp = buildResponsesResponse(
							pr.RequestID, consumerModel(pr), msg, usage,
							pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash,
							pr.Traits)
					} else if pr.ConsumerEndpoint == completionsEndpoint ||
						pr.ConsumerEndpoint == messagesEndpoint {
						resp = buildGenericEndpointResponse(pr, msg, usage)
					} else {
						chatResp := buildNonStreamingResponse(pr.RequestID, consumerModel(pr), msg, usage, pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash)
						applyChatCompletionMetadataToResponse(&chatResp, pr)
						resp = chatResp
					}
					s.noteInferenceSuccess(pr)
					writeNonStreamBody(w, pr.Profile.Parent(), resp)
				case <-ctx.Done():
					if errors.Is(ctx.Err(), context.DeadlineExceeded) {
						s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
						s.updateInferenceRouteOutcomeForPending(pr, preResponseTimeoutOutcome(pr, "usage_timeout_before_response"))
						writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
					} else {
						s.refundReservedBalance(pr, "client_gone:"+pr.RequestID)
						s.updateInferenceRouteOutcomeForPending(pr, clientGoneBeforeResponseOutcome(pr))
					}
				}
				return
			}
			chunk := providerChunk.Data
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause)
			s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, errMsg))
			s.writeGenericProviderError(w, errMsg)
			return

		case <-ctx.Done():
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
				s.updateInferenceRouteOutcomeForPending(pr, preResponseTimeoutOutcome(pr, "response_timeout_before_response"))
				writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "request timed out"))
			} else {
				s.refundReservedBalance(pr, "client_gone:"+pr.RequestID)
				s.updateInferenceRouteOutcomeForPending(pr, clientGoneBeforeResponseOutcome(pr))
			}
			return
		}
	}
}

// rewriteRawFinishReason corrects a provider-reported "stop" finish_reason to
// "length" on a raw chat.completion object when the authoritative token counts
// show generation consumed the entire max-tokens budget.
func rewriteRawFinishReason(obj map[string]any, usage protocol.UsageInfo, requestedMax int) {
	if !truncatedByMaxTokens(usage, requestedMax) {
		return
	}
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for _, rawChoice := range choices {
		if choice, ok := rawChoice.(map[string]any); ok {
			if fr, _ := choice["finish_reason"].(string); fr == "stop" {
				choice["finish_reason"] = "length"
			}
		}
	}
}

func normalizeCompleteChatResponse(obj map[string]any, requestedModel string) {
	if requestedModel != "" {
		obj["model"] = requestedModel
	}
	for _, key := range []string{"system_fingerprint"} {
		if v, ok := obj[key]; ok && v == nil {
			delete(obj, key)
		}
	}
	choices, ok := obj["choices"].([]any)
	if !ok {
		return
	}
	for choicePosition, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		choiceIndex := normalizedChoiceIndex(choice["index"], choicePosition)
		if message, ok := choice["message"].(map[string]any); ok {
			normalizeCompleteMessage(message, choiceIndex)
		}
		if delta, ok := choice["delta"].(map[string]any); ok {
			normalizeCompleteMessage(delta, choiceIndex)
		}
	}
}

func canonicalReasoningDetails(reasoning string, choiceIndex int) []types.ReasoningDetail {
	return []types.ReasoningDetail{{
		Type:   "reasoning.text",
		Text:   reasoning,
		ID:     "reasoning-text-" + strconv.Itoa(choiceIndex),
		Format: "unknown",
		Index:  0,
	}}
}

func normalizedChoiceIndex(raw any, fallback int) int {
	switch index := raw.(type) {
	case int:
		if index >= 0 {
			return index
		}
	case int64:
		converted := int(index)
		if index >= 0 && int64(converted) == index {
			return converted
		}
	case float64:
		intLimit := math.Ldexp(1, strconv.IntSize-1)
		if math.IsNaN(index) || math.IsInf(index, 0) || index < 0 || index >= intLimit || math.Trunc(index) != index {
			break
		}
		return int(index)
	case json.Number:
		if parsed, err := strconv.ParseInt(index.String(), 10, strconv.IntSize); err == nil && parsed >= 0 {
			return int(parsed)
		}
	}
	return fallback
}

func normalizeCompleteMessage(message map[string]any, choiceIndex int) {
	var extractedReasoning string
	if content, ok := message["content"]; !ok || content == nil {
		message["content"] = ""
	} else if contentText, ok := content.(string); ok {
		cleaned, reasoning := stripThinkBlocks(contentText)
		message["content"] = cleaned
		extractedReasoning = reasoning
	}

	if rc, ok := message["reasoning_content"]; ok {
		if rcText, ok := rc.(string); ok && rcText != "" {
			mergeReasoningField(message, rcText)
		}
		delete(message, "reasoning_content")
	}
	if reasoning, ok := message["reasoning"]; ok && reasoning == nil {
		delete(message, "reasoning")
	}
	if extractedReasoning != "" {
		mergeReasoningField(message, extractedReasoning)
	}
	if reasoning, ok := message["reasoning"].(string); ok && reasoning != "" {
		message["reasoning_content"] = reasoning
		if _, hasDetails := message["reasoning_details"]; !hasDetails {
			message["reasoning_details"] = canonicalReasoningDetails(reasoning, choiceIndex)
		}
	}
	for _, key := range []string{"tool_calls", "refusal"} {
		if v, ok := message[key]; ok && v == nil {
			delete(message, key)
		}
	}
}

func mergeReasoningField(message map[string]any, reasoning string) {
	reasoning = strings.TrimSpace(reasoning)
	if reasoning == "" {
		return
	}
	if existing, ok := message["reasoning"].(string); ok && strings.TrimSpace(existing) != "" {
		if existing != reasoning && !strings.Contains(existing, reasoning) {
			message["reasoning"] = existing + "\n\n" + reasoning
		}
		return
	}
	message["reasoning"] = reasoning
}

func stripThinkBlocks(text string) (string, string) {
	matches := thinkBlockPattern.FindAllStringSubmatch(text, -1)
	reasoningParts := make([]string, 0, len(matches)+1)
	found := len(matches) > 0
	for _, match := range matches {
		if len(match) > 1 {
			if part := strings.TrimSpace(match[1]); part != "" {
				reasoningParts = append(reasoningParts, part)
			}
		}
	}
	cleaned := thinkBlockPattern.ReplaceAllString(text, "")
	lower := strings.ToLower(cleaned)
	if idx := strings.Index(lower, "<think>"); idx >= 0 {
		found = true
		if part := strings.TrimSpace(cleaned[idx+len("<think>"):]); part != "" {
			reasoningParts = append(reasoningParts, part)
		}
		cleaned = cleaned[:idx]
	}
	if !found {
		return text, ""
	}
	return strings.TrimSpace(cleaned), strings.Join(reasoningParts, "\n\n")
}

// normalizeSSEChunk fixes fields in SSE chunks to match the OpenAI spec.
// Some backends emit "content":null instead of "content":"",
// and include "usage":null which strict parsers (ForgeCode, Codex) reject
// because they expect usage to be either absent or a full object.
func normalizeSSEChunk(chunk string) string {
	line := strings.TrimPrefix(chunk, "data: ")
	// Only trigger the expensive JSON parse for fields we actually fix.
	// "finish_reason":null appears on every chunk but we don't touch it, so
	// the gates scan for the fixable `"<key>":null` shapes and the reasoning
	// aliases in a pass each (sse_normalize_gate.go) instead of one
	// strings.Contains per field.
	if !sseChunkNeedsNullFix(line) && !sseChunkHasReasoningField(line) {
		return chunk
	}
	return rewriteSSEChunkFields(chunk, line)
}

// rewriteSSEChunkFields is normalizeSSEChunk's slow path: the JSON round-trip
// that rewrites null delta fields, drops null top-level fields, mirrors the
// reasoning aliases and synthesises reasoning_details. line is chunk without
// its "data: " prefix. Returns chunk unchanged when nothing needed fixing or
// the payload is not a JSON object.
func rewriteSSEChunkFields(chunk, line string) string {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &raw); err != nil {
		return chunk
	}

	changed := false

	// Remove top-level null fields (usage, system_fingerprint, etc.)
	// ForgeCode expects usage to be absent or a full object, not null.
	for _, key := range []string{"usage", "system_fingerprint"} {
		if v, ok := raw[key]; ok && string(v) == "null" {
			delete(raw, key)
			changed = true
		}
	}

	// Fix null fields inside choices[].delta
	if choicesRaw, ok := raw["choices"]; ok {
		var choices []map[string]json.RawMessage
		if err := json.Unmarshal(choicesRaw, &choices); err == nil {
			for i, choice := range choices {
				if deltaRaw, ok := choice["delta"]; ok {
					var delta map[string]json.RawMessage
					if err := json.Unmarshal(deltaRaw, &delta); err == nil {
						deltaChanged := false
						for _, field := range []string{"content", "reasoning_content", "reasoning", "refusal"} {
							if v, ok := delta[field]; ok && string(v) == "null" {
								delta[field] = json.RawMessage(`""`)
								deltaChanged = true
							}
						}
						if v, ok := delta["tool_calls"]; ok && string(v) == "null" {
							delta["tool_calls"] = json.RawMessage(`[]`)
							deltaChanged = true
						}
						// reasoning_content is provider-canonical for streaming deltas.
						// If either alias is present, emit both with the same value, even
						// when that value is empty; empty values never produce details.
						reasoningRaw, hasReasoning := delta["reasoning"]
						reasoningContentRaw, hasReasoningContent := delta["reasoning_content"]
						reasoning := nonEmptyRawString(reasoningRaw)
						reasoningContent := nonEmptyRawString(reasoningContentRaw)
						chosenReasoning := reasoningContent
						chosenRaw := reasoningContentRaw
						if chosenReasoning == "" && reasoning != "" {
							chosenReasoning = reasoning
							chosenRaw = reasoningRaw
						} else if chosenReasoning == "" && !hasReasoningContent {
							chosenRaw = reasoningRaw
						}
						if hasReasoning || hasReasoningContent {
							if !hasReasoning || !bytes.Equal(reasoningRaw, chosenRaw) {
								delta["reasoning"] = chosenRaw
								deltaChanged = true
							}
							if !hasReasoningContent || !bytes.Equal(reasoningContentRaw, chosenRaw) {
								delta["reasoning_content"] = chosenRaw
								deltaChanged = true
							}
						}
						if _, hasDetails := delta["reasoning_details"]; !hasDetails && chosenReasoning != "" {
							choiceIndex := normalizedRawChoiceIndex(choice["index"], i)
							details, err := json.Marshal(canonicalReasoningDetails(chosenReasoning, choiceIndex))
							if err == nil {
								delta["reasoning_details"] = details
								deltaChanged = true
							}
						}
						if deltaChanged {
							choices[i]["delta"], _ = json.Marshal(delta)
							changed = true
						}
					}
				}
			}
			if changed {
				raw["choices"], _ = json.Marshal(choices)
			}
		}
	}

	if !changed {
		return chunk
	}

	out, err := json.Marshal(raw)
	if err != nil {
		return chunk
	}
	return "data: " + string(out)
}

func nonEmptyRawString(raw json.RawMessage) string {
	var value string
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil {
		return ""
	}
	return value
}

func normalizedRawChoiceIndex(raw json.RawMessage, fallback int) int {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] == '"' {
		return fallback
	}
	var index json.Number
	if json.Unmarshal(raw, &index) == nil {
		return normalizedChoiceIndex(index, fallback)
	}
	return fallback
}

// maxLogicalToolCalls caps how many logical tool calls a single stream may
// reconstruct. Chunks come from providers, which are only semi-trusted: a
// buggy or malicious provider could otherwise stream an unbounded number of
// distinct-id tool-call deltas and grow the reconstruction (and its wire-index
// tracking) without limit. Real parallel-tool-call fan-out is tiny (typically
// <= 4 calls), so 128 is far above anything legitimate while bounding the
// worst case. Past the cap, deltas that would START a new logical call are
// dropped (counted + logged); argument fragments for already-kept calls still
// accumulate, so kept calls are never truncated or corrupted.
const maxLogicalToolCalls = 128

// toolCallWireIndex reads an accumulated tool-call entry's wire index.
// Entries are always created with an int "index" (toolCallAccumulator.apply),
// so the comma-ok is defensive only: a corrupt entry cannot panic the request
// path — it sorts last, keeping arrival order relative to other corrupt
// entries.
func toolCallWireIndex(tc map[string]any) int {
	idx, ok := tc["index"].(int)
	if !ok {
		return math.MaxInt
	}
	return idx
}

// toolCallAccumulator reconstructs logical tool calls from streamed deltas.
// Logical calls are kept in ARRIVAL order (calls) because a wire index is
// NOT unique: legacy provider builds emit every parallel call with index 0
// (E6; the engine at this branch's pin assigns distinct indices, but the
// fleet updates slowly), so index-keyed storage alone would let a second
// call overwrite the first's id/name and concatenate both argument streams
// into one corrupted call.
// activeByIndex maps each wire index to the position (in calls) of its
// CURRENT logical call — the one still receiving that index's id-less
// argument fragments; a delta whose non-empty id DIFFERS from that entry's
// non-empty id starts a NEW logical call, so well-behaved indexed streams
// are unchanged.
type toolCallAccumulator struct {
	calls         []map[string]any
	activeByIndex map[int]int
	// droppedDeltas counts deltas swallowed past maxLogicalToolCalls
	// (dropped new logical calls and their argument fragments).
	droppedDeltas int
}

func newToolCallAccumulator() *toolCallAccumulator {
	return &toolCallAccumulator{activeByIndex: map[int]int{}}
}

// apply folds one streamed delta into the accumulator. Past
// maxLogicalToolCalls, a delta that would start a new logical call is
// dropped and its wire index forgotten, so the dropped call's later id-less
// fragments can never accumulate onto a kept call; kept calls keep receiving
// their own fragments as usual.
func (a *toolCallAccumulator) apply(tc streamToolCallDelta) {
	pos, ok := a.activeByIndex[tc.Index]
	if ok && tc.ID != "" {
		if existingID, _ := a.calls[pos]["id"].(string); existingID != "" && existingID != tc.ID {
			// A NEW id on an already-active wire index is a new logical
			// call, not a continuation (the all-index-0 engine shape) —
			// never merge two calls into one.
			ok = false
		}
	}
	if !ok {
		if len(a.calls) >= maxLogicalToolCalls {
			// Cap reached: drop the new logical call. The kept call at
			// this wire index (if any) is complete as-is. This also
			// bounds activeByIndex: keys are only ever added alongside a
			// kept call, so both structures stay <= maxLogicalToolCalls
			// entries no matter how many distinct ids or sparse wire
			// indices are streamed.
			a.droppedDeltas++
			delete(a.activeByIndex, tc.Index)
			return
		}
		entry := map[string]any{
			"index": tc.Index,
			"function": map[string]any{
				"arguments": "",
			},
		}
		a.calls = append(a.calls, entry)
		pos = len(a.calls) - 1
		a.activeByIndex[tc.Index] = pos
	}
	entry := a.calls[pos]
	if tc.ID != "" {
		entry["id"] = tc.ID
	}
	if tc.Type != "" {
		entry["type"] = tc.Type
	}
	fn, fnOK := entry["function"].(map[string]any)
	if !fnOK {
		// Defensive: entries are always created with a function map —
		// never panic the request path on a corrupt entry.
		fn = map[string]any{}
		entry["function"] = fn
	}
	if tc.Function.Name != "" {
		fn["name"] = tc.Function.Name
	}
	args, _ := fn["arguments"].(string)
	fn["arguments"] = args + tc.Function.Arguments
}

// finalize returns the reconstructed calls (nil when there are none),
// ordered by wire index for well-behaved indexed streams; the stable sort
// preserves ARRIVAL order among equal indices (the all-index-0 shape), and —
// unlike the old dense 0..n-1 map walk — sparse indices are never dropped.
// The internal "index" key is stripped from the returned maps.
func (a *toolCallAccumulator) finalize() []map[string]any {
	if len(a.calls) == 0 {
		return nil
	}
	sort.SliceStable(a.calls, func(i, j int) bool {
		return toolCallWireIndex(a.calls[i]) < toolCallWireIndex(a.calls[j])
	})
	out := make([]map[string]any, 0, len(a.calls))
	for _, tc := range a.calls {
		delete(tc, "index")
		out = append(out, tc)
	}
	return out
}

// extractedMessage holds the reconstructed assistant message from SSE chunks,
// including text content, reasoning, and any tool calls.
type extractedMessage struct {
	Content                 string           `json:"content"`
	Reasoning               string           `json:"reasoning,omitempty"`
	ReasoningDetails        any              `json:"reasoning_details,omitempty"`
	ReasoningDetailsPresent bool             `json:"-"`
	ToolCalls               []map[string]any `json:"tool_calls,omitempty"`
	FinishReason            string           `json:"-"`
}

// extractMessage retains the historical reasoning-first behavior used by
// Responses and generic endpoint fallbacks.
func extractMessage(chunks []string) extractedMessage {
	return extractMessageWithReasoningPolicy(chunks, false)
}

func extractMessageWithReasoningPolicy(chunks []string, preferReasoningContent bool) extractedMessage {
	var contentBuilder strings.Builder
	var reasoningBuilder strings.Builder
	finishReason := ""
	var reasoningDetails any
	reasoningDetailsPresent := false
	reasoningDetailsNull := false
	// See toolCallAccumulator for the logical-call model (arrival order,
	// non-unique wire indices, the maxLogicalToolCalls cap).
	acc := newToolCallAccumulator()

	for _, chunk := range chunks {
		line := strings.TrimPrefix(chunk, "data: ")
		line = strings.TrimSpace(line)
		if line == "" || line == "[DONE]" {
			continue
		}

		var parsed map[string]json.RawMessage
		if err := json.Unmarshal([]byte(line), &parsed); err != nil {
			continue
		}

		choicesRaw, ok := parsed["choices"]
		if !ok {
			continue
		}
		var choices []struct {
			Delta struct {
				Content          string                `json:"content"`
				Reasoning        string                `json:"reasoning"`
				ReasoningContent string                `json:"reasoning_content"`
				ReasoningDetails json.RawMessage       `json:"reasoning_details"`
				ToolCalls        []streamToolCallDelta `json:"tool_calls,omitempty"`
			} `json:"delta"`
			Message struct {
				Content          string                `json:"content"`
				Reasoning        string                `json:"reasoning"`
				ReasoningContent string                `json:"reasoning_content"`
				ReasoningDetails json.RawMessage       `json:"reasoning_details"`
				ToolCalls        []streamToolCallDelta `json:"tool_calls,omitempty"`
			} `json:"message"`
			FinishReason *string `json:"finish_reason"`
		}
		if err := json.Unmarshal(choicesRaw, &choices); err != nil {
			continue
		}

		for _, c := range choices {
			if c.FinishReason != nil && *c.FinishReason != "" {
				finishReason = *c.FinishReason
			}
			if c.Delta.Content != "" {
				contentBuilder.WriteString(c.Delta.Content)
			} else if c.Message.Content != "" {
				contentBuilder.WriteString(c.Message.Content)
			}
			if preferReasoningContent {
				if c.Delta.ReasoningContent != "" {
					reasoningBuilder.WriteString(c.Delta.ReasoningContent)
				} else if c.Delta.Reasoning != "" {
					reasoningBuilder.WriteString(c.Delta.Reasoning)
				} else if c.Message.ReasoningContent != "" {
					reasoningBuilder.WriteString(c.Message.ReasoningContent)
				} else if c.Message.Reasoning != "" {
					reasoningBuilder.WriteString(c.Message.Reasoning)
				}
			} else if c.Delta.Reasoning != "" {
				reasoningBuilder.WriteString(c.Delta.Reasoning)
			} else if c.Delta.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Delta.ReasoningContent)
			} else if c.Message.Reasoning != "" {
				reasoningBuilder.WriteString(c.Message.Reasoning)
			} else if c.Message.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Message.ReasoningContent)
			}
			for _, rawDetails := range []json.RawMessage{c.Delta.ReasoningDetails, c.Message.ReasoningDetails} {
				trimmed := bytes.TrimSpace(rawDetails)
				if len(trimmed) == 0 {
					continue
				}
				if trimmed[0] == '[' {
					var details []json.RawMessage
					if json.Unmarshal(rawDetails, &details) != nil {
						continue
					}
					if !reasoningDetailsPresent || reasoningDetailsNull {
						reasoningDetails = make([]json.RawMessage, 0, len(details))
						reasoningDetailsPresent = true
						reasoningDetailsNull = false
					}
					if accumulated, ok := reasoningDetails.([]json.RawMessage); ok {
						reasoningDetails = append(accumulated, details...)
					}
				} else if !reasoningDetailsPresent || reasoningDetailsNull {
					reasoningDetails = json.RawMessage(append([]byte(nil), rawDetails...))
					reasoningDetailsPresent = true
					reasoningDetailsNull = bytes.Equal(trimmed, []byte("null"))
				}
			}
			toolCalls := c.Delta.ToolCalls
			if len(toolCalls) == 0 {
				toolCalls = c.Message.ToolCalls
			}
			for _, tc := range toolCalls {
				acc.apply(tc)
			}
		}
	}

	content := contentBuilder.String()
	reasoning := reasoningBuilder.String()
	if cleaned, extractedReasoning := stripThinkBlocks(content); extractedReasoning != "" {
		content = cleaned
		if strings.TrimSpace(reasoning) != "" {
			reasoning += "\n\n" + extractedReasoning
		} else {
			reasoning = extractedReasoning
		}
	}
	msg := extractedMessage{
		Content:                 content,
		Reasoning:               reasoning,
		ReasoningDetails:        reasoningDetails,
		ReasoningDetailsPresent: reasoningDetailsPresent,
		FinishReason:            finishReason,
	}
	if acc.droppedDeltas > 0 {
		log.Printf("WARN: extractMessage: logical tool-call cap (%d) reached; dropped %d tool-call delta(s) from excess calls", maxLogicalToolCalls, acc.droppedDeltas)
	}
	msg.ToolCalls = acc.finalize()
	return msg
}

// resolveReasoningTokens returns the reasoning-token count to report.
// It prefers the provider's tokenizer-accurate count
// (UsageInfo.ReasoningTokens) and falls back to the coarse "all
// completion tokens" estimate only for older providers that emit
// reasoning content without a count — so a reasoning response never
// reports zero reasoning tokens, while up-to-date providers report the
// real split.
// injectReasoningDetailIntoRawUsage splices
// completion_tokens_details.reasoning_tokens into a passthrough
// chat.completion object when the provider reported an accurate
// reasoning-token count (UsageInfo.ReasoningTokens) and the raw usage
// object didn't already carry the detail. It never overrides a value the
// provider already supplied, and is a no-op when there is no reasoning
// count or no usage object.
func injectReasoningDetailIntoRawUsage(obj map[string]any, usage protocol.UsageInfo) {
	if usage.ReasoningTokens <= 0 {
		return
	}
	usageObj, ok := obj["usage"].(map[string]any)
	if !ok {
		return
	}
	details, _ := usageObj["completion_tokens_details"].(map[string]any)
	if details == nil {
		details = map[string]any{}
	}
	if _, exists := details["reasoning_tokens"]; exists {
		return
	}
	details["reasoning_tokens"] = usage.ReasoningTokens
	usageObj["completion_tokens_details"] = details
	obj["usage"] = usageObj
}

func isSSEDoneEventGroup(group string) bool {
	lines := strings.Split(group, "\n")
	data := make([]string, 0, len(lines))
	for _, line := range lines {
		if value, ok := sseDataValue(line); ok {
			data = append(data, value)
		}
	}
	if len(data) > 0 {
		return strings.TrimSpace(strings.Join(data, "\n")) == "[DONE]"
	}
	return len(lines) == 1 &&
		strings.TrimSpace(strings.TrimPrefix(group, "\uFEFF")) == "[DONE]"
}

// stripSSEDoneEvents removes provider-owned SSE terminators while preserving
// sibling events in the same chunk. The coordinator owns stream termination so
// authoritative usage, signature, and metadata events always precede [DONE].
func stripSSEDoneEvents(chunk string) (string, bool) {
	if !strings.Contains(chunk, "[DONE]") {
		return chunk, false
	}
	normalized := strings.ReplaceAll(strings.ReplaceAll(chunk, "\r\n", "\n"), "\r", "\n")
	groups := strings.Split(normalized, "\n\n")
	kept := make([]string, 0, len(groups))
	removed := false
	for _, group := range groups {
		if isSSEDoneEventGroup(group) {
			removed = true
			continue
		}
		kept = append(kept, group)
	}
	if !removed {
		return chunk, false
	}
	return strings.Join(kept, "\n\n"), true
}

// isResponsesAPIEventChunk reports whether a streamed chunk is a Responses API
// SSE event (its parsed top-level "type" is a "response.*" event). It parses
// rather than substring-matches: a chat.completion content delta whose text
// quotes "response.created"/"response.output_text.delta" (e.g. a user asking
// about the Responses API) must NOT be misread as a Responses stream, which
// would make the relay skip chat-completions termination handling (usage
// splicing, [DONE] swallowing, normalizeSSEChunk) and corrupt the stream.
func isResponsesAPIEventChunk(chunk string) bool {
	line := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(chunk), "data:"))
	// Cheap gate: every Responses event names a response.* type at top level.
	if !strings.Contains(line, `"response.`) {
		return false
	}
	var ev struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal([]byte(line), &ev); err != nil {
		return false
	}
	return strings.HasPrefix(ev.Type, "response.")
}

// isBoilerplateChunk reports whether a streamed provider chunk carries no
// consumer-visible output yet: the preamble emitted BEFORE the failure-prone
// work (media decode, template render, vision prefill) begins. The dispatch
// loop holds such chunks instead of committing on them, so a provider that
// dies after its preamble is retried invisibly instead of surfacing an
// in-band SSE error with zero retries.
//
// Boilerplate is exactly:
//   - a chat.completion.chunk whose choices[].delta carries ONLY the assistant
//     role — content/reasoning/refusal absent, null, or "" (some backends ride
//     an empty content along with the role), tool_calls absent/null/empty,
//     finish_reason null, no usage object; or
//   - a Responses API response.created / response.in_progress lifecycle event
//     (the parsed top-level "type" equals exactly one of those — NOT a mere
//     substring match: a chat content delta whose text quotes "response.created"
//     must still commit).
//
// Everything else — content or tool_call deltas, finish chunks, usage-only
// chunks, [DONE], complete responses, unparseable data — commits the dispatch.
func isBoilerplateChunk(chunk string) bool {
	line := strings.TrimPrefix(strings.TrimPrefix(chunk, "data: "), "data:")
	line = strings.TrimSpace(line)
	// Responses API lifecycle preamble: classify ONLY when the parsed top-level
	// "type" is exactly response.created / response.in_progress. A chat content
	// delta that merely mentions that text (e.g. a user asking about the
	// Responses API) parses as a chat.completion.chunk and falls through to the
	// role-only logic below — it is NOT boilerplate.
	if strings.Contains(line, `"response.created"`) || strings.Contains(line, `"response.in_progress"`) {
		var ev struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal([]byte(line), &ev); err == nil {
			if ev.Type == "response.created" || ev.Type == "response.in_progress" {
				return true
			}
		}
	}
	// Cheap gate: the role preamble always names the role; chunks that can't
	// be it (content deltas, finish chunks, [DONE], garbage) skip the parse.
	if !strings.Contains(line, `"role"`) {
		return false
	}
	var parsed struct {
		Object  string          `json:"object"`
		Usage   json.RawMessage `json:"usage"`
		Choices []struct {
			Delta        map[string]json.RawMessage `json:"delta"`
			FinishReason *string                    `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(line), &parsed); err != nil {
		return false
	}
	if parsed.Object != "chat.completion.chunk" {
		return false
	}
	if len(parsed.Usage) > 0 && string(parsed.Usage) != "null" {
		return false
	}
	if len(parsed.Choices) == 0 {
		return false
	}
	for _, choice := range parsed.Choices {
		if choice.FinishReason != nil {
			return false
		}
		if _, hasRole := choice.Delta["role"]; !hasRole {
			return false
		}
		for field, v := range choice.Delta {
			switch field {
			case "role":
				// The preamble itself.
			case "content", "reasoning_content", "reasoning", "refusal":
				if s := string(v); s != `""` && s != "null" {
					return false
				}
			case "tool_calls":
				if s := string(v); s != "null" && s != "[]" {
					return false
				}
			default:
				// Unknown delta payload — assume it's real output.
				return false
			}
		}
	}
	return true
}

// parseUsageOnlyStreamChunk decodes a terminal include_usage chunk (empty choices
// + a non-null usage object, carrying the final usage and no content delta) and
// returns the parsed object. ok is false for any other chunk. Parsing here once
// lets the caller hold the object and finalize it at stream end without re-parsing.
func parseUsageOnlyStreamChunk(chunk string) (obj map[string]any, ok bool) {
	line := strings.TrimPrefix(chunk, "data: ")
	// Cheap gate: skip the parse for content deltas and usage:null chunks.
	if !strings.Contains(line, `"usage"`) || strings.Contains(line, `"usage":null`) {
		return nil, false
	}
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return nil, false
	}
	if u, uok := obj["usage"].(map[string]any); !uok || u == nil {
		return nil, false
	}
	if choices, _ := obj["choices"].([]any); len(choices) != 0 {
		return nil, false
	}
	return obj, true
}

// finalizeUsageChunk renders the held terminal usage chunk for chat-completions
// streaming: it splices the provider's authoritative reasoning count into
// completion_tokens_details (no-op when there is none), strips a null
// system_fingerprint, and rewrites the build id to the public alias — marshalling
// ONCE (obj is already parsed). Returns "" if it can't be marshalled.
func finalizeUsageChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	injectReasoningDetailIntoRawUsage(obj, usage)
	injectCacheDetailIntoRawUsage(obj, usage)
	if v, present := obj["system_fingerprint"]; present && v == nil {
		delete(obj, "system_fingerprint")
	}
	if pr.PublicModel != "" && pr.PublicModel != pr.Model {
		obj["model"] = pr.PublicModel
	}
	b, err := json.Marshal(obj)
	if err != nil {
		return ""
	}
	return "data: " + string(b)
}

// parseFinishStreamChunk decodes a chunk whose choices carry a non-null
// finish_reason (the terminal content chunk). ok is false for any other
// chunk. The parsed object is held by the caller and finalized at stream end
// once the authoritative token counts are known.
func parseFinishStreamChunk(chunk string) (map[string]any, bool) {
	line := strings.TrimPrefix(chunk, "data: ")
	if !strings.Contains(line, `"finish_reason":"`) {
		return nil, false
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		return nil, false
	}
	choices, _ := obj["choices"].([]any)
	for _, c := range choices {
		if m, ok := c.(map[string]any); ok {
			if fr, _ := m["finish_reason"].(string); fr != "" {
				return obj, true
			}
		}
	}
	return nil, false
}

// finalizeFinishChunk renders the held terminal finish chunk: when the
// authoritative completion-token count shows generation hit the max-tokens
// bound, a provider-reported "stop" is corrected to "length" (the engine
// doesn't distinguish natural stop from truncation). Also rewrites the build
// id to the public alias. Returns "" if it can't be marshalled.
func finalizeFinishChunk(obj map[string]any, usage protocol.UsageInfo, pr *registry.PendingRequest) string {
	if truncatedByMaxTokens(usage, pr.RequestedMaxTokens) {
		if choices, ok := obj["choices"].([]any); ok {
			for _, c := range choices {
				if m, ok := c.(map[string]any); ok {
					if fr, _ := m["finish_reason"].(string); fr == "stop" {
						m["finish_reason"] = "length"
					}
				}
			}
		}
	}
	if pr.PublicModel != "" && pr.PublicModel != pr.Model {
		obj["model"] = pr.PublicModel
	}
	b, err := json.Marshal(obj)
	if err != nil {
		return ""
	}
	return "data: " + string(b)
}

// truncatedByMaxTokens reports whether generation consumed the entire
// max-tokens budget. requestedMax is the effective bound — the consumer's
// explicit max_tokens or the coordinator-injected default — so hitting it
// means the engine cut generation short.
func truncatedByMaxTokens(usage protocol.UsageInfo, requestedMax int) bool {
	return requestedMax > 0 && usage.CompletionTokens >= requestedMax
}

// effectiveFinishReason resolves the finish_reason for a reconstructed
// response. The provider engine reports "stop" unconditionally, so a
// truncation-aware reason is re-derived from the authoritative token counts.
func effectiveFinishReason(extracted string, hasToolCalls bool, usage protocol.UsageInfo, requestedMax int) string {
	if extracted != "" && extracted != "stop" {
		return extracted
	}
	if truncatedByMaxTokens(usage, requestedMax) {
		return "length"
	}
	if hasToolCalls {
		return "tool_calls"
	}
	return "stop"
}

func resolveReasoningTokens(usage protocol.UsageInfo, reasoning string) uint64 {
	if usage.ReasoningTokens > 0 {
		return uint64(usage.ReasoningTokens)
	}
	if reasoning != "" {
		return uint64(usage.CompletionTokens)
	}
	return 0
}

func buildResponsesUsage(promptTokens, completionTokens, reasoningTokens, cachedTokens uint64) types.ResponsesUsage {
	return types.ResponsesUsage{
		InputTokens:        int(promptTokens),
		InputTokensDetail:  types.ResponsesUsageDetail{CachedTokens: int(cachedTokens)},
		OutputTokens:       int(completionTokens),
		OutputTokensDetail: types.ResponsesUsageDetail{ReasoningTokens: int(reasoningTokens)},
	}
}

func buildResponsesIncompleteDetails(finishReason string) *types.ResponsesIncompleteDetail {
	switch finishReason {
	case "length":
		return &types.ResponsesIncompleteDetail{Reason: "max_output_tokens"}
	case "content_filter":
		return &types.ResponsesIncompleteDetail{Reason: "content_filter"}
	default:
		return nil
	}
}

func responseItemID(prefix, requestID string, index int) string {
	return fmt.Sprintf("%s_%s_%d", prefix, strings.ReplaceAll(requestID, "-", ""), index)
}

func appendResponsesOutputItems(output []any, requestID string, msg extractedMessage) []any {
	index := len(output)
	if msg.Reasoning != "" {
		output = append(output, map[string]any{
			"type": "reasoning",
			"id":   responseItemID("rs", requestID, index),
			"summary": []map[string]any{{
				"type": "summary_text",
				"text": msg.Reasoning,
			}},
		})
		index++
	}
	if msg.Content != "" || len(msg.ToolCalls) == 0 {
		output = append(output, map[string]any{
			"type":   "message",
			"role":   "assistant",
			"status": "completed",
			"id":     responseItemID("msg", requestID, index),
			"content": []map[string]any{{
				"type":        "output_text",
				"text":        msg.Content,
				"annotations": []any{},
			}},
		})
		index++
	}
	for _, tc := range msg.ToolCalls {
		fn, _ := tc["function"].(map[string]any)
		callID, _ := tc["id"].(string)
		if callID == "" {
			callID = responseItemID("call", requestID, index)
		}
		name, _ := fn["name"].(string)
		args, _ := fn["arguments"].(string)
		output = append(output, map[string]any{
			"type":      "function_call",
			"id":        responseItemID("fc", requestID, index),
			"call_id":   callID,
			"name":      name,
			"arguments": args,
			"status":    "completed",
		})
		index++
	}
	return output
}

// finalizeResponsesEnvelope fills the spec-required envelope fields of a
// Responses object: status derived from incomplete_details, and the
// always-present defaults (tool_choice, tools, metadata, parallel_tool_calls).
func finalizeResponsesEnvelope(
	r *types.ResponsesResponse,
	traits registry.RequestTraits,
) {
	if r.IncompleteDetail != nil {
		r.Status = "incomplete"
	} else {
		r.Status = "completed"
	}
	r.ToolChoice, r.ParallelToolCalls = responsesToolPolicy(traits)
	if r.Tools == nil {
		r.Tools = []any{}
	}
	if r.Metadata == nil {
		r.Metadata = map[string]any{}
	}
}

func buildResponsesResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, requestedMax int, seSignature, responseHash string, policies ...registry.RequestTraits) types.ResponsesResponse {
	reasoningTokens := resolveReasoningTokens(usage, msg.Reasoning)
	finishReason := effectiveFinishReason(msg.FinishReason, len(msg.ToolCalls) > 0, usage, requestedMax)
	resp := types.ResponsesResponse{
		ID:               "resp_" + strings.ReplaceAll(requestID, "-", ""),
		Object:           "response",
		CreatedAt:        time.Now().Unix(),
		Model:            model,
		Output:           appendResponsesOutputItems(nil, requestID, msg),
		Usage:            buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens, uint64(usage.CachedTokens)),
		IncompleteDetail: buildResponsesIncompleteDetails(finishReason),
	}
	var traits registry.RequestTraits
	if len(policies) > 0 {
		traits = policies[0]
	}
	finalizeResponsesEnvelope(&resp, traits)
	if seSignature != "" {
		resp.SESignature = seSignature
		resp.ResponseHash = responseHash
	}
	return resp
}

func firstChoice(resp types.ChatCompletionResponse) *types.ChatCompletionChoice {
	if len(resp.Choices) == 0 {
		return nil
	}
	return &resp.Choices[0]
}

func chatUsageToResponsesUsage(resp types.ChatCompletionResponse, reasoning string) types.ResponsesUsage {
	reasoningTokens := 0
	if d := resp.Usage.CompletionTokensDetails; d != nil && d.ReasoningTokens > 0 {
		reasoningTokens = d.ReasoningTokens
	} else if reasoning != "" {
		reasoningTokens = resp.Usage.CompletionTokens
	}
	cachedTokens := 0
	if details := resp.Usage.PromptTokensDetails; details != nil {
		cachedTokens = details.CachedTokens
	}
	return buildResponsesUsage(uint64(resp.Usage.PromptTokens), uint64(resp.Usage.CompletionTokens), uint64(reasoningTokens), uint64(cachedTokens))
}

func chatCompletionToResponses(resp types.ChatCompletionResponse, requestedModel, seSignature, responseHash string, policies ...registry.RequestTraits) types.ResponsesResponse {
	requestID := strings.TrimPrefix(resp.ID, "chatcmpl-")
	if requestID == "" {
		requestID = uuid.NewString()
	}
	created := int(resp.Created)
	if created <= 0 {
		created = int(time.Now().Unix())
	}

	msg := extractedMessage{}
	finishReason := ""
	if choice := firstChoice(resp); choice != nil {
		finishReason = choice.FinishReason
		msg.Content = choice.Message.Content
		msg.Reasoning = choice.Message.Reasoning
		msg.ToolCalls = choice.Message.ToolCalls
	}

	r := types.ResponsesResponse{
		ID:        "resp_" + strings.ReplaceAll(requestID, "-", ""),
		Object:    "response",
		CreatedAt: int64(created),
		Model:     requestedModel,
		Output:    appendResponsesOutputItems(nil, requestID, msg),
		Usage:     chatUsageToResponsesUsage(resp, msg.Reasoning),
	}
	if finishReason != "" && finishReason != "stop" {
		r.IncompleteDetail = buildResponsesIncompleteDetails(finishReason)
	}
	var traits registry.RequestTraits
	if len(policies) > 0 {
		traits = policies[0]
	}
	finalizeResponsesEnvelope(&r, traits)
	if seSignature != "" {
		r.SESignature = seSignature
		r.ResponseHash = responseHash
	}
	return r
}

func buildNonStreamingResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, requestedMax int, seSignature, responseHash string) types.ChatCompletionResponse {
	message := types.ChatCompletionMessage{
		Role:    "assistant",
		Content: msg.Content,
	}
	if msg.Reasoning != "" {
		message.Reasoning = msg.Reasoning
		message.ReasoningContent = msg.Reasoning
	}
	if msg.ReasoningDetailsPresent {
		message.ReasoningDetails = msg.ReasoningDetails
	} else if msg.Reasoning != "" {
		message.ReasoningDetails = canonicalReasoningDetails(msg.Reasoning, 0)
	}

	if len(msg.ToolCalls) > 0 {
		message.ToolCalls = msg.ToolCalls
	}
	finishReason := effectiveFinishReason(msg.FinishReason, len(msg.ToolCalls) > 0, usage, requestedMax)

	resp := types.ChatCompletionResponse{
		ID:      "chatcmpl-" + requestID,
		Object:  "chat.completion",
		Created: time.Now().Unix(),
		Model:   model,
		Choices: []types.ChatCompletionChoice{{
			Index:        0,
			Message:      message,
			FinishReason: finishReason,
		}},
		Usage: types.ChatCompletionUsage{
			PromptTokens:     usage.PromptTokens,
			CompletionTokens: usage.CompletionTokens,
			TotalTokens:      usage.PromptTokens + usage.CompletionTokens,
		},
	}

	// Surface the OpenAI-standard reasoning-token breakdown when present
	// so non-streaming chat-completions consumers can read it (the
	// streaming path carries it on the provider's verbatim usage chunk).
	if rt := resolveReasoningTokens(usage, msg.Reasoning); rt > 0 {
		resp.Usage.CompletionTokensDetails = &types.CompletionTokensDetails{
			ReasoningTokens: int(rt),
		}
	}
	if usage.CachedTokens > 0 {
		resp.Usage.PromptTokensDetails = &types.PromptTokensDetails{CachedTokens: usage.CachedTokens}
	}

	if seSignature != "" {
		resp.SESignature = seSignature
		resp.ResponseHash = responseHash
	}

	return resp
}

// handleListModels handles GET /v1/models.
//
// Returns a deduplicated list of models across all connected providers,
// including attestation metadata (trust level, Secure Enclave status,
// provider count) for each model. Capacity fields (routable_providers,
// warm_providers, can_accept) are included from the live capacity snapshot.
// hideAliasBuild marks a concrete build id as hidden from the standalone model
// listing — a build behind a public alias is only ever exposed through that
// alias. Only builds that are actually in the catalog are hidden: a build absent
// from the catalog can't appear in the listing anyway, and adding it would
// pollute the hidden set (e.g. an alias pointing at a not-yet-registered build).
// Empty ids are ignored.
// ── Multi-key management handlers (GET/POST/PATCH/DELETE /v1/keys) ────

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
	// Ingress-anchored like the chat handler (see handleChatCompletions).
	timing := &registry.RequestTiming{ReceivedAt: ingressStartFromContext(r.Context())}
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
	clientSetMaxTokens := explicitMaxTokens(parsed) > 0
	ensureMaxTokensBound(parsed, false, genericMaxOutput)

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	// See the chat handler: routing-only expected completion beside the bound.
	expectedCompletionTokens := s.expectedCompletionTokensForRouting(model, parsed, clientSetMaxTokens, requestedMaxTokens)
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
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens, publicModel)
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
		// Nothing was generated: return the upfront OTPM charge (once).
		s.creditUnusedOutputAdmission(consumerKey, keyIDFromContext(r.Context()), tokenAdmission)
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
	// Populated by refreshGenericBody(model) below (and on every model
	// fallback); an eager routingTraitsForModel(model) here lowered the body
	// once more only to be overwritten before anything read it.
	var routingTraits registry.RequestTraits
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
	admissionModel := model
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
	if model != admissionModel {
		// Alias fallback rewrote the build (see the chat handler): re-derive the
		// routing estimate and the per-build first-content clock.
		expectedCompletionTokens = s.expectedCompletionTokensForRouting(model, parsed, clientSetMaxTokens, requestedMaxTokens)
		genericDeadline = s.FirstContentDeadline(model, estimatedPromptTokens)
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
		// Routing-only decode length for the scheduler's cost term (routing_estimates.go).
		expectedCompletionTokens: expectedCompletionTokens,
	}
	d.run()
}
