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
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/payments"
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

	// preambleContentTimeout is the budget from the first boilerplate chunk to
	// the first CONTENT chunk when the TTFT deadline has already expired. A
	// provider that produced only preamble (role delta / Responses lifecycle)
	// has written ZERO bytes to the client, so a role-then-stall zombie must
	// fail over instead of pinning the request for the full inferenceTimeout.
	// 90s comfortably covers the measured pre-content tail (vision prefill is
	// 6-30s); genuine cold model loads signal via AcceptedCh and keep the full
	// inferenceTimeout.
	preambleContentTimeout = 90 * time.Second

	// chunkBufferSize is the channel buffer size for SSE chunks flowing from
	// the provider to the consumer. A larger buffer prevents dropped chunks
	// when the consumer reads slowly.
	chunkBufferSize = 256

	// maxDispatchAttempts is the maximum number of provider dispatch attempts
	// before returning an error to the consumer. The coordinator retries on
	// the same or a different provider when the first attempt fails (e.g.
	// backend crashed, model not loaded after idle shutdown).
	maxDispatchAttempts = 3

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
	// Past the cap the chunk commits the dispatch — the pre-deferral behavior.
	maxHeldBoilerplate = 8

	// cancelWriteTimeout bounds how long a cancel write to the provider can
	// block. Using context.Background() unbounded here risks hanging the HTTP
	// handler goroutine when a WebSocket is half-dead.
	cancelWriteTimeout = 2 * time.Second
)

var thinkBlockPattern = regexp.MustCompile(`(?is)<think>(.*?)</think>\s*`)

// ttftDeadline returns the TTFT budget for a request based on prompt size.
// Base: 5 seconds + 1ms per estimated input token. This meets the OpenRouter
// SLA of TTFT < 5s + 1ms/input_token.
func ttftDeadline(estimatedPromptTokens int) time.Duration {
	base := 5 * time.Second
	perToken := time.Duration(estimatedPromptTokens) * time.Millisecond
	return base + perToken
}

// sendProviderCancel sends a Cancel message for the given request to the
// provider with a bounded timeout so a half-dead WebSocket doesn't hang the
// caller. Errors are logged at debug level because a disconnect race is the
// expected case — the provider may already be gone.
func (s *Server) sendProviderCancel(provider *registry.Provider, requestID string) {
	if provider == nil || provider.Conn == nil {
		return
	}
	cancelMsg := protocol.CancelMessage{Type: protocol.TypeCancel, RequestID: requestID}
	cancelData, err := json.Marshal(cancelMsg)
	if err != nil {
		s.logger.Error("failed to marshal cancel message", "request_id", requestID, "error", err)
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), cancelWriteTimeout)
	defer cancel()
	if err := provider.EnqueueText(ctx, cancelData); err != nil {
		s.logger.Debug("failed to send cancel (provider may have disconnected)",
			"request_id", requestID, "error", err)
	}
}

func writeProviderInferenceRequest(ctx context.Context, provider *registry.Provider, data []byte) error {
	if provider == nil || provider.Conn == nil {
		return errors.New("provider websocket is not connected")
	}
	return provider.WriteText(ctx, data)
}

// cancelDispatch cleans up a speculative dispatch participant that lost the
// race (or a failed/timed-out attempt): removes the pending request, marks the
// provider idle, sends a cancel over WebSocket so the provider stops generating
// tokens, and refunds this attempt's provider-specific reservation top-up.
//
// The top-up refund only runs if THIS call actually removed the pending request
// (RemovePending returned non-nil). If settlement (handleComplete) already
// claimed it via its own RemovePending, we must not also refund — that would
// double-credit the consumer.
func (s *Server) cancelDispatch(provider *registry.Provider, pr *registry.PendingRequest) {
	if provider == nil || pr == nil {
		return
	}
	removed := provider.RemovePending(pr.RequestID)
	s.registry.SetProviderIdle(provider.ID)
	s.sendProviderCancel(provider, pr.RequestID)
	if removed != nil {
		s.refundProviderExtra(pr)
	}
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

// noteInferenceError feeds the per-provider-model inference-error breaker for a
// provider-side error received on a pending request's ErrorCh (any phase, pre-
// or post-commit; the breaker itself only counts sickness-shaped 500/502/504)
// and emits the cool-down metric on the transition into quarantine.
func (s *Server) noteInferenceError(providerID string, pr *registry.PendingRequest, statusCode int) {
	if providerID == "" || pr == nil {
		return
	}
	if s.registry.RecordInferenceError(providerID, pr.Model, statusCode, pr.Traits.CooldownShape()) {
		s.ddIncr("routing.cooldown_entered", []string{"model:" + pr.Model})
	}
}

// noteInferenceSuccess clears the inference-error strike state for the serving
// provider-model pair on a clean completion (streaming relay ended without a
// provider error; non-streaming response assembled OK).
func (s *Server) noteInferenceSuccess(pr *registry.PendingRequest) {
	if pr == nil || pr.ProviderID == "" {
		return
	}
	s.registry.RecordInferenceSuccess(pr.ProviderID, pr.Model, pr.Traits.CooldownShape())
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
func (s *Server) noteDispatchProviderError(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, held *[]string) (discardedHeld bool) {
	if provider != nil {
		s.noteInferenceError(provider.ID, pr, statusCode)
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
func (s *Server) resolveRequestedModel(parsed map[string]any, rawBody []byte, requested string, allowedProviderSerials []string, policy selfRoutePolicy) (buildModel, publicModel string, newRawBody []byte, ok bool) {
	buildID, isAlias, resolved := s.registry.ResolveModelConstrained(
		requested, allowedProviderSerials, policy.ownerAccountID, policy.enabled, policy.prefer)
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

// maybeFallbackAliasCapacity keeps public aliases available during a desired-build
// saturation event. Alias resolution intentionally prefers Desired when it is
// routable, but if every desired provider is transiently full and Previous has
// immediate capacity, route this request to Previous instead of returning a fast
// 429. Hard constraints and permanent model-too-large failures are handled by the
// caller and do not use this fallback. The TTFT estimate for Previous is also
// returned so the caller does not need to recompute it.
func (s *Server) maybeFallbackAliasCapacity(parsed map[string]any, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string) (string, int, int, int, time.Duration, bool, bool) {
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false
	}
	target, ok := s.registry.AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false
	}
	if !s.registry.IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false
	}
	candidates, rejections, tooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(target.Previous, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedProviderSerials...)
	if candidates <= 0 {
		return currentModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, false
	}
	parsed["model"] = target.Previous
	return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, true
}

func (s *Server) maybeFallbackAliasTTFT(parsed map[string]any, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string) (string, int, int, int, time.Duration, bool, bool) {
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false
	}
	target, ok := s.registry.AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false
	}
	if !s.registry.IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false
	}
	candidates, rejections, tooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(target.Previous, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedProviderSerials...)
	if candidates <= 0 || ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold) {
		return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, false
	}
	parsed["model"] = target.Previous
	return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, true
}

func ttftTooSlow(bestTTFT time.Duration, hasTTFT bool, threshold time.Duration) bool {
	return hasTTFT && bestTTFT > threshold
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
		fmt.Sprintf("all providers for model %q are above the %ds TTFT target (best estimate %.1fs); retry after %ds", publicModel, int(math.Ceil(threshold.Seconds())), bestTTFT.Seconds(), retryAfter),
		withCode("rate_limit_exceeded")))
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

// dispatchOneProvider encrypts and sends an inference request to a single
// provider. It returns the pending request and provider on success, or an
// error string on failure. The excludeProviders set is updated on failure.
// selfRoutePolicy and its resolvers live in self_route.go.

type routeDecisionRecorder func(*registry.Provider, *registry.PendingRequest, registry.RoutingDecision)

func (s *Server) dispatchOneProvider(
	r *http.Request,
	model string,
	publicModel string,
	rawBody []byte,
	consumerKey string,
	consumerLocation *store.ProviderLocation,
	reservedMicroUSD int64,
	estimatedPromptTokens int,
	requestedMaxTokens int,
	tokenAdmission registry.TokenAdmission,
	requiresVision bool,
	traits registry.RequestTraits,
	allowedProviderSerials []string,
	isResponsesAPI bool,
	policy selfRoutePolicy,
	timing *registry.RequestTiming,
	serviceReservation bool,
	cacheAffinityKey string,
	excludeProviders map[string]struct{},
	attempt int,
	recordRoute routeDecisionRecorder,
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	lastErr string,
	lastErrCode int,
) {
	requestID := uuid.New().String()
	pr = &registry.PendingRequest{
		RequestID: requestID,
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
		CacheAffinityKey:       cacheAffinityKey,
		ReservedMicroUSD:       reservedMicroUSD,
		BaseReservedMicroUSD:   reservedMicroUSD,
		ServiceReservation:     serviceReservation,
		AllowedProviderSerials: allowedProviderSerials,
		SelfRouteOnly:          policy.enabled,
		PreferOwner:            policy.prefer,
		OwnerAccountID:         policy.ownerAccountID,
		FreeSelfRoute:          policy.enabled,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan string, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
		Timing:                 timing,
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
	if !policy.enabled && !policy.prefer && s.ttftHardReject {
		pr.MaxTTFTMs = float64(ttftDeadline(estimatedPromptTokens).Milliseconds())
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

	provider, decision = s.registry.ReserveProviderEx(model, pr, excludeList()...)
	if provider == nil {
		// Providers serve this model but none can physically fit it: don't make
		// the caller queue/retry for something that will never load.
		if decision.CandidateCount == 0 && decision.CapacityRejections == 0 && decision.ModelTooLargeRejections > 0 {
			return nil, nil, decision, errModelTooLarge, http.StatusServiceUnavailable
		}
		// Providers are available but all exceed the TTFT ceiling. Fail fast
		// with a retryable 429 rather than queueing or routing to a slow
		// provider.
		if decision.TTFTRejections > 0 {
			return nil, nil, decision, errTTFTTooSlow, http.StatusTooManyRequests
		}
		return nil, nil, decision, "no provider available", http.StatusServiceUnavailable
	}
	pendingCleanup := true
	cleanupPending := func() {
		if pendingCleanup {
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			pendingCleanup = false
		}
	}
	defer cleanupPending()
	if pr.Timing != nil {
		pr.Timing.RoutedAt = time.Now()
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
				return nil, nil, decision, "insufficient funds for provider price", http.StatusPaymentRequired
			}
			s.logger.Error("provider reservation failed (DB error)", "provider_id", provider.ID, "error", err)
			return nil, nil, decision, "service temporarily unavailable — please retry", http.StatusServiceUnavailable
		}
	}
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
		return nil, nil, decision, "no provider with E2E encryption", http.StatusServiceUnavailable
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, "provider public key invalid", http.StatusServiceUnavailable
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, "failed to generate session keys", http.StatusInternalServerError
	}

	// Pre-fix providers crash on a vision request carrying sampling penalties;
	// strip them for those providers only (see bodyForProvider).
	sealedBody := bodyForProvider(rawBody, requiresVision, provider)
	encrypted, err := e2e.Encrypt(sealedBody, providerPubKey, sessionKeys)
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, "failed to encrypt request", http.StatusInternalServerError
	}
	if pr.Timing != nil {
		pr.Timing.EncryptedAt = time.Now()
	}

	wireMsg := map[string]any{
		"type":       protocol.TypeInferenceRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}

	pr.SessionPrivKey = &sessionKeys.PrivateKey
	// pr.ReservedMicroUSD was already set in the struct literal and may have
	// been increased by reserveAdditionalForProvider above. Don't overwrite.

	data, err := json.Marshal(wireMsg)
	if err != nil {
		refundExtra()
		cleanupPending()
		return nil, nil, decision, "failed to marshal request", http.StatusInternalServerError
	}
	if pr.Timing != nil {
		pr.Timing.DispatchedAt = time.Now()
	}
	if err := writeProviderInferenceRequest(r.Context(), provider, data); err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, "failed to send request to provider", http.StatusBadGateway
	}
	pendingCleanup = false

	return provider, pr, decision, "", 0
}

func intFromRequestValue(v any) (int, bool) {
	switch x := v.(type) {
	case int:
		return x, true
	case int32:
		return int(x), true
	case int64:
		return int(x), true
	case float64:
		return int(x), true
	case json.Number:
		n, err := x.Int64()
		if err != nil {
			return 0, false
		}
		return int(n), true
	default:
		return 0, false
	}
}

// approximateTokenCount returns a rough token estimate for routing and queue
// admission. The len/4 heuristic is a reasonable average for English text
// with GPT-style BPE tokenizers. This value feeds into the scheduler's
// capacity checks (pendingTokenBudget, freeMemoryAdmits) where a tighter
// estimate produces better routing decisions.
//
// For billing reservation (where underestimation causes provider shortfall),
// use approximateTokenCountUpperBound instead.
func approximateTokenCount(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case string:
		if x == "" {
			return 0
		}
		tokens := len(x) / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return 0
		}
		tokens := len(b) / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	}
}

// approximateTokenCountUpperBound returns a guaranteed upper bound on the
// number of tokens a BPE tokenizer would produce for v. Every BPE vocabulary
// starts with one token per byte and can only merge, so len(text) >= tokens
// for any model family, any language, forever. This is used only for billing
// reservation to ensure the pre-flight debit always covers the actual cost.
//
// Using len(text) over-reserves by ~3-4x on average for English prose, but
// the difference is refunded immediately after inference completes, so
// consumers are never overcharged — they only need sufficient balance to
// cover the reservation hold.
func approximateTokenCountUpperBound(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case string:
		return len(x)
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return 0
		}
		return len(b)
	}
}

func estimatePromptTokens(parsed map[string]any) int {
	total := 0
	if v, ok := parsed["messages"]; ok {
		total += messagesPromptTokens(v)
	}
	if v, ok := parsed["input"]; ok {
		total += inputPromptTokens(v)
	}
	if v, ok := parsed["prompt"]; ok {
		total += approximateTokenCount(v)
	}
	if total == 0 {
		total = approximateTokenCount(parsed)
	}
	return total
}

// estimateBillingPromptTokens returns a guaranteed upper bound on prompt
// tokens for billing reservation. Uses byte-length (not len/4) so the
// pre-flight reservation always covers actual cost. This value must NOT
// be used for routing — see estimatePromptTokens for that.
func estimateBillingPromptTokens(parsed map[string]any) int {
	total := 0
	if v, ok := parsed["messages"]; ok {
		// Billing MUST stay a guaranteed upper bound (len(bytes) >= tokens for any
		// BPE tokenizer), so it keeps counting full message bytes — including a
		// base64 image's bytes and every non-content field (role, tool_calls,
		// name). Switching to the media-aware flat count here would DROP those
		// fields and under-reserve for tool-calling requests. Over-reservation on a
		// large image is safe (it is refunded after inference); the routing/ITPM
		// estimate (estimatePromptTokens) is the media-aware one.
		total += approximateTokenCountUpperBound(v)
	}
	if v, ok := parsed["input"]; ok {
		total += approximateTokenCountUpperBound(v)
	}
	if v, ok := parsed["prompt"]; ok {
		total += approximateTokenCountUpperBound(v)
	}
	if total == 0 {
		total = approximateTokenCountUpperBound(parsed)
	}
	return total
}

// Media prompt-token costs. A vision encoder turns each image/video into a
// bounded number of soft tokens (Gemma 4 caps around a few hundred per image)
// regardless of the base64 byte length, so counting a `data:` URI as text
// inflates the estimate by orders of magnitude — distorting routing admission and
// over-reserving balance. These flat per-media costs keep both sane.
const (
	imagePromptTokenCost = 300
	videoPromptTokenCost = 1500
)

// isMediaPartType reports whether an OpenAI/OpenRouter content-part type denotes
// image or video input.
func isMediaPartType(t string) bool {
	switch t {
	// OpenAI chat (image_url/video_url), OpenAI Responses (input_image/input_video),
	// and Anthropic /v1/messages content blocks ({"type":"image"|"video","source":…}).
	case "image_url", "input_image", "image", "video_url", "input_video", "video":
		return true
	}
	return false
}

// messageContentTokens estimates ROUTING prompt tokens for one message's
// `content`, counting text parts as text (len/4) and each image/video part as a
// flat media cost (never the base64 length). Used only for the routing/ITPM
// estimate; billing uses approximateTokenCountUpperBound (a guaranteed upper
// bound that intentionally still counts the base64 bytes).
func messageContentTokens(content any) int {
	textTokens := func(s string) int {
		if s == "" {
			return 0
		}
		if t := len(s) / 4; t > 0 {
			return t
		}
		return 1
	}
	switch c := content.(type) {
	case string:
		return textTokens(c)
	case []any:
		total := 0
		for _, part := range c {
			pm, ok := part.(map[string]any)
			if !ok {
				continue
			}
			typ, _ := pm["type"].(string)
			switch {
			case typ == "text" || typ == "input_text":
				if s, ok := pm["text"].(string); ok {
					total += textTokens(s)
				}
			case typ == "image_url" || typ == "input_image" || typ == "image":
				total += imagePromptTokenCost
			case typ == "video_url" || typ == "input_video" || typ == "video":
				total += videoPromptTokenCost
			default:
				if b, err := json.Marshal(pm); err == nil {
					total += len(b) / 4
				}
			}
		}
		return total
	default:
		return approximateTokenCount(content)
	}
}

// messagesPromptTokens sums media-aware routing content tokens across a messages
// array. Falls back to the len/4 heuristic when messages isn't the standard
// array shape.
func messagesPromptTokens(messages any) int {
	arr, ok := messages.([]any)
	if !ok {
		return approximateTokenCount(messages)
	}
	total := 0
	for _, m := range arr {
		mm, ok := m.(map[string]any)
		if !ok {
			total += approximateTokenCount(m)
			continue
		}
		total += 4 // small per-message framing (role + delimiters)
		total += messageContentTokens(mm["content"])
	}
	return total
}

// inputPromptTokens estimates the Responses API `input` field. A string input
// is plain text (len/4). Structured input is an array of message-like items with
// `content` parts, so reuse the same media-aware content estimator as chat
// messages instead of counting JSON wrapper bytes.
func inputPromptTokens(input any) int {
	switch x := input.(type) {
	case string:
		return approximateTokenCount(x)
	case []any:
		total := 0
		for _, item := range x {
			switch m := item.(type) {
			case string:
				total += approximateTokenCount(m)
			case map[string]any:
				content, ok := m["content"]
				if !ok {
					total += approximateTokenCount(m)
					continue
				}
				total += 4 // role/type framing, matching messagesPromptTokens.
				total += messageContentTokens(content)
			default:
				total += approximateTokenCount(item)
			}
		}
		return total
	default:
		return approximateTokenCount(input)
	}
}

// contentPartsHaveMedia reports whether a `content` value (a content-part array)
// carries any image/video part.
func contentPartsHaveMedia(content any) bool {
	parts, ok := content.([]any)
	if !ok {
		return false
	}
	for _, part := range parts {
		pm, ok := part.(map[string]any)
		if !ok {
			continue
		}
		if typ, _ := pm["type"].(string); isMediaPartType(typ) {
			return true
		}
	}
	return false
}

// detectMediaRequirement reports whether the request carries image/video input.
// The coordinator sees plaintext at this point (sealedTransport decrypts before
// the handler), so this drives the vision routing gate and the fail-fast "no
// vision-capable provider" response. It scans both the Chat Completions
// `messages[].content` parts and the Responses API `input[].content` parts so a
// media request on either surface is gated (never silently routed text-blind).
func detectMediaRequirement(parsed map[string]any) bool {
	if messages, ok := parsed["messages"].([]any); ok {
		for _, m := range messages {
			if mm, ok := m.(map[string]any); ok && contentPartsHaveMedia(mm["content"]) {
				return true
			}
		}
	}
	// Responses API: `input` may be a string (no media) or an array of items,
	// each carrying `content` parts in the same image_url/input_image shape.
	if input, ok := parsed["input"].([]any); ok {
		for _, item := range input {
			if im, ok := item.(map[string]any); ok && contentPartsHaveMedia(im["content"]) {
				return true
			}
		}
	}
	return false
}

// requestHasTools reports whether the request carries a non-empty top-level
// "tools" array (Chat Completions and Responses API share the field name).
// Drives Traits.HasTools so tool-bearing requests only route to providers whose
// binaries survive tool-schema template rendering (version floor + per-model
// template_render_ok gate in the scheduler).
func requestHasTools(parsed map[string]any) bool {
	tools, ok := parsed["tools"].([]any)
	return ok && len(tools) > 0
}

func requestCacheAffinityKey(parsed map[string]any) string {
	raw, ok := parsed["prompt_cache_key"].(string)
	if !ok || raw == "" {
		return ""
	}
	const maxPromptCacheKeyBytes = 512
	if len(raw) > maxPromptCacheKeyBytes {
		return ""
	}
	sum := sha256.Sum256([]byte(raw))
	return fmt.Sprintf("%x", sum[:])
}

func estimateRequestedMaxTokens(parsed map[string]any) int {
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if n, ok := intFromRequestValue(parsed[key]); ok && n > 0 {
			if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
				return n * copies
			}
			return n
		}
	}
	if copies, ok := intFromRequestValue(parsed["n"]); ok && copies > 1 {
		return 256 * copies
	}
	return 256
}

func parseProviderSerialAllowlist(parsed map[string]any) ([]string, bool, error) {
	var rawValues []any
	provided := false
	for _, key := range []string{"provider_serial", "provider_serials"} {
		v, ok := parsed[key]
		if !ok {
			continue
		}
		provided = true
		switch x := v.(type) {
		case string:
			rawValues = append(rawValues, x)
		case []any:
			rawValues = append(rawValues, x...)
		default:
			return nil, true, fmt.Errorf("%s must be a string or array of strings", key)
		}
	}
	if !provided {
		return nil, false, nil
	}

	seen := make(map[string]struct{}, len(rawValues))
	ids := make([]string, 0, len(rawValues))
	for _, raw := range rawValues {
		id, ok := raw.(string)
		if !ok {
			return nil, true, fmt.Errorf("provider_serials must contain only strings")
		}
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, true, fmt.Errorf("provider_serials must include at least one provider serial")
	}
	return ids, true, nil
}

func stripProviderRoutingFields(parsed map[string]any) bool {
	changed := false
	for _, key := range []string{"provider_serial", "provider_serials"} {
		if _, ok := parsed[key]; ok {
			delete(parsed, key)
			changed = true
		}
	}
	return changed
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
	var parsed map[string]any
	if json.Unmarshal(rawBody, &parsed) != nil {
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

// estimateRetryAfter returns a suggested wait time in seconds before retrying
// a request for the given model. Based on queue depth as a rough proxy for
// fleet backlog. OpenRouter uses the Retry-After header to schedule retries.
func (s *Server) estimateRetryAfter(model string) int {
	queueDepth := s.registry.Queue().QueueSize(model)
	if queueDepth == 0 {
		return 2 // Light load, retry soon
	}
	// Rough estimate: each queued request takes ~3 seconds to drain.
	estimate := queueDepth * 3
	if estimate < 2 {
		estimate = 2
	}
	if estimate > 30 {
		estimate = 30
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

func copyJSONMap(in map[string]any) map[string]any {
	out := make(map[string]any, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func responsesContentText(content any) string {
	switch c := content.(type) {
	case nil:
		return ""
	case string:
		return c
	case []any:
		parts := make([]string, 0, len(c))
		for _, part := range c {
			switch p := part.(type) {
			case string:
				if p != "" {
					parts = append(parts, p)
				}
			case map[string]any:
				if text, _ := p["text"].(string); text != "" {
					parts = append(parts, text)
					continue
				}
				if p["type"] == "input_image" || p["type"] == "input_file" {
					// Text models cannot consume binary Responses parts yet.
					// Preserve the turn shape without leaking URLs or blobs.
					parts = append(parts, fmt.Sprintf("[%s omitted]", p["type"]))
				}
			}
		}
		return strings.Join(parts, "\n")
	default:
		b, err := json.Marshal(c)
		if err != nil {
			return fmt.Sprint(c)
		}
		return string(b)
	}
}

func responsesInputToChatMessages(input any) ([]map[string]any, error) {
	switch v := input.(type) {
	case string:
		return []map[string]any{{"role": "user", "content": v}}, nil
	case []any:
		messages := make([]map[string]any, 0, len(v))
		for _, raw := range v {
			item, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if typ, _ := item["type"].(string); typ != "" {
				switch typ {
				case "message":
					role, _ := item["role"].(string)
					if role == "" {
						role = "user"
					}
					if role == "developer" {
						role = "system"
					}
					messages = append(messages, map[string]any{
						"role":    role,
						"content": responsesContentText(item["content"]),
					})
				case "function_call":
					callID, _ := item["call_id"].(string)
					if callID == "" {
						callID, _ = item["id"].(string)
					}
					name, _ := item["name"].(string)
					args, _ := item["arguments"].(string)
					messages = append(messages, map[string]any{
						"role":    "assistant",
						"content": "",
						"tool_calls": []map[string]any{{
							"id":   callID,
							"type": "function",
							"function": map[string]any{
								"name":      name,
								"arguments": args,
							},
						}},
					})
				case "function_call_output":
					callID, _ := item["call_id"].(string)
					messages = append(messages, map[string]any{
						"role":         "tool",
						"tool_call_id": callID,
						"content":      responsesContentText(item["output"]),
					})
				case "reasoning":
					// Reasoning items are model-side metadata, not prompt text.
					continue
				default:
					return nil, fmt.Errorf("unsupported Responses input item type %q", typ)
				}
				continue
			}

			role, _ := item["role"].(string)
			if role == "" {
				continue
			}
			if role == "developer" {
				role = "system"
			}
			messages = append(messages, map[string]any{
				"role":    role,
				"content": responsesContentText(item["content"]),
			})
		}
		if len(messages) == 0 {
			return nil, fmt.Errorf("Responses input did not contain any chat-compatible messages")
		}
		return messages, nil
	default:
		return nil, fmt.Errorf("Responses input must be a string or array")
	}
}

func responsesToolsToChatTools(raw any) ([]any, error) {
	tools, ok := raw.([]any)
	if !ok || len(tools) == 0 {
		return nil, nil
	}
	out := make([]any, 0, len(tools))
	for _, rawTool := range tools {
		tool, ok := rawTool.(map[string]any)
		if !ok {
			continue
		}
		typ, _ := tool["type"].(string)
		if typ == "" || typ == "function" {
			name, _ := tool["name"].(string)
			if name == "" {
				if fn, _ := tool["function"].(map[string]any); fn != nil {
					out = append(out, tool)
					continue
				}
				return nil, fmt.Errorf("function tool is missing name")
			}
			fn := map[string]any{"name": name}
			if description, ok := tool["description"].(string); ok {
				fn["description"] = description
			}
			if parameters, ok := tool["parameters"]; ok {
				fn["parameters"] = parameters
			}
			out = append(out, map[string]any{
				"type":     "function",
				"function": fn,
			})
			continue
		}
		return nil, fmt.Errorf("unsupported Responses tool type %q", typ)
	}
	return out, nil
}

func responsesToolChoiceToChat(raw any) (any, error) {
	choice, ok := raw.(map[string]any)
	if !ok {
		return raw, nil
	}
	typ, _ := choice["type"].(string)
	if typ == "function" {
		name, _ := choice["name"].(string)
		if name == "" {
			return nil, fmt.Errorf("function tool_choice is missing name")
		}
		return map[string]any{
			"type": "function",
			"function": map[string]any{
				"name": name,
			},
		}, nil
	}
	return raw, nil
}

func responsesTextFormatToChatResponseFormat(raw any) any {
	text, ok := raw.(map[string]any)
	if !ok {
		return nil
	}
	format, ok := text["format"].(map[string]any)
	if !ok {
		return nil
	}
	switch format["type"] {
	case "json_object":
		return map[string]any{"type": "json_object"}
	case "json_schema":
		return map[string]any{
			"type":        "json_schema",
			"json_schema": format,
		}
	}
	return nil
}

func responsesRequestToChatCompletions(parsed map[string]any) (map[string]any, error) {
	messages, err := responsesInputToChatMessages(parsed["input"])
	if err != nil {
		return nil, err
	}

	out := copyJSONMap(parsed)
	delete(out, "input")
	delete(out, "endpoint")
	delete(out, "max_output_tokens")
	delete(out, "text")
	out["messages"] = messages
	if maxTokens := explicitMaxTokens(parsed); maxTokens > 0 {
		out["max_tokens"] = maxTokens
	}
	if tools, err := responsesToolsToChatTools(parsed["tools"]); err != nil {
		return nil, err
	} else if len(tools) > 0 {
		out["tools"] = tools
	}
	if choice, err := responsesToolChoiceToChat(parsed["tool_choice"]); err != nil {
		return nil, err
	} else if choice != nil {
		out["tool_choice"] = choice
	}
	if responseFormat := responsesTextFormatToChatResponseFormat(parsed["text"]); responseFormat != nil {
		out["response_format"] = responseFormat
	}
	return out, nil
}

// handleChatCompletions handles POST /v1/chat/completions.
//
// This is the main inference endpoint. It validates the request, finds an
// available provider for the requested model, forwards the request via
// WebSocket, and either streams SSE chunks or assembles a complete response.
//
// The raw request body is passed through to the provider, preserving all
// OpenAI-compatible fields (tools, tool_choice, response_format, top_p, etc.)
// that would otherwise be lost if we parsed into a typed struct.
func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}

	// Shared prelude: read body, normalize tool schemas, parse, require a model,
	// enforce the per-key model allowlist. (See parseInferencePrelude.)
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	rawBody := prelude.rawBody
	parsed := prelude.parsed
	model := prelude.model

	// Accept either chat completions format (messages) or Responses API
	// format (input). The provider's backend handles both natively.
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

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "bad_param",
			httpStatus:      http.StatusBadRequest,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist && stripProviderRoutingFields(parsed) {
		rawBody, _ = marshalForwardBody(parsed)
	}

	// "Use my own machine, for free" opt-in. The signal is the
	// X-Darkbloom-Route header (OpenAI-client-safe: invisible to the body
	// schema) OR a per-key hard ceiling. The header can only *request*
	// self-routing; it cannot name a machine — ownership is matched on the
	// coordinator-stamped provider AccountID, so nothing here is forgeable.
	policy := s.resolveSelfRoutePolicy(r)

	// Resolve a public alias (e.g. "gemma-4-26b") to a concrete build id, now
	// that routing constraints (serial allowlist / self-route) are known so the
	// pick only considers builds the constrained provider set can actually
	// serve. From here on `model` is the build (routing/billing/serving) while
	// `publicModel` is echoed back so the consumer never sees the quant.
	buildModel, publicModel, resolvedBody, ok := s.resolveRequestedModel(
		parsed, rawBody, model, allowedProviderSerials, policy)
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
	model, rawBody = buildModel, resolvedBody

	// Vision gating: a request carrying image/video input must land on a provider
	// advertising a vision-capable (VLM) build of this model, or the media is
	// silently dropped and the answer is image-blind. Fail fast with a clear error
	// when the fleet has no such provider (e.g. before the gemma fleet finishes
	// updating to 0.6.0); the routing layer enforces the same gate per dispatch.
	requiresVision := detectMediaRequirement(parsed)
	// Tool-bearing requests are routed only to providers that can render tool
	// schemas without crashing (version floor + template_render_ok gate);
	// detected here, alongside the media gate, while the parsed body is hot.
	hasTools := requestHasTools(parsed)
	cacheAffinityKey := requestCacheAffinityKey(parsed)
	// Shared media/tools fail-fast. Chat completions additionally rejects media
	// sent via the Responses API surface (input-without-messages), because the
	// Responses→chat lowering doesn't carry image/video parts through.
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		input != nil && len(messages) == 0, policy, allowedProviderSerials) {
		return
	}

	isResponsesAPI := input != nil && len(messages) == 0

	// Inject model-specific defaults from the registry: reasoning_parser
	// and max_tokens bound. Single DB lookup (cached for platform prices).
	maxOutputBound := defaultMaxOutputTokens
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		// Reasoning parser from runtime_parameters.
		if _, hasRP := parsed["reasoning_parser"]; !hasRP && rec.RuntimeParameters != nil {
			if rp, ok := rec.RuntimeParameters["reasoning_parser"]; ok {
				parsed["reasoning_parser"] = rp
				rawBody, _ = marshalForwardBody(parsed)
			}
		}
		// Use the registry's max_output_length as the default max_tokens
		// bound instead of the hardcoded 8192. This lets models like
		// GPT-OSS 20B (32K output) generate longer responses when the
		// consumer omits max_tokens.
		if rec.MaxOutputLength > 0 {
			maxOutputBound = rec.MaxOutputLength
		}
	}

	// Bound the generation so the pre-flight reservation covers it. If the
	// consumer didn't set max_tokens, inject the model's max_output_length
	// (or defaultMaxOutputTokens as fallback). Without this bound the
	// provider could return more tokens than we reserved for, and the
	// silent post-inference charge failure would hand the consumer free
	// inference (GitHub issue #33).
	if ensureMaxTokensBound(parsed, isResponsesAPI, maxOutputBound) {
		rawBody, _ = marshalForwardBody(parsed)
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	deadline := ttftDeadline(estimatedPromptTokens)
	timing.ParsedAt = time.Now()

	if isResponsesAPI {
		providerParsed, err := responsesRequestToChatCompletions(parsed)
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
		rawBody, _ = marshalForwardBody(providerParsed)
	}

	// Per-account token rate limiting (ITPM/OTPM) — the industry-standard
	// token throttle alongside RPM. Charged upfront from the input estimate
	// and the bounded max_tokens (OpenAI-style). Runs before the balance
	// reservation so a throttled request never touches billing.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation — atomically debit the worst-case cost
	// using the byte-length upper bound for prompt tokens (guaranteed >=
	// actual tokens for any BPE tokenizer) plus max_tokens we just bounded
	// the generation to. The post-inference charge refunds any unused
	// portion. The routing estimate (estimatedPromptTokens, len/4) is kept
	// separate so scheduler capacity checks aren't over-inflated.
	var reservedMicroUSD int64
	serviceReservation := false
	// Self-route is free: skip the pre-flight balance reservation and the
	// per-key spend cap entirely. A zero-balance owner must never be blocked
	// from running on their own machine, and a self_route_only key never spends.
	if s.billing != nil && !policy.enabled {
		consumerKey := consumerKeyFromContext(r.Context())
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation so a
		// capped key never debits the account ledger.
		if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "balance",
				reasonCode:            "insufficient_quota",
				httpStatus:            http.StatusPaymentRequired,
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
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
			return
		}
		var err error
		serviceReservation, err = s.reserveInitialBalance(consumerKey, model, reservedMicroUSD)
		if err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.recordRejection(rejectionInfo{
					r:                     r,
					stage:                 "balance",
					reasonCode:            "insufficient_funds",
					httpStatus:            http.StatusPaymentRequired,
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
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				s.writeServiceUnavailable(w, model)
			}
			return
		}
	}
	timing.ReservedAt = time.Now()

	// Refund reservation on early errors (before inference starts).
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.releaseInitialReservation(consumerKeyFromContext(r.Context()), model, reservedMicroUSD, serviceReservation)
		}
	}

	// Reject requests for models not in the catalog.
	if !s.registry.IsModelInCatalog(model) {
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

	// Self-route pre-flight: confirm the caller owns an online machine that can
	// serve this model, with precise errors and no fallback to the paid fleet.
	if policy.enabled {
		if s.selfRouteUnavailable(w, r, policy.ownerAccountID, model) {
			refundReservation()
			return
		}
	} else if policy.prefer {
		// Prefer mode: SKIP the public fleet pre-flight. QuickCapacityCheck has
		// no owner-trust relaxation, so it would spuriously 429/503 a request
		// whose own (idle, possibly un-enrolled / private-only) machine could
		// serve it while the public fleet is busy. Dispatch does owned-first
		// routing with a paid public fallback and the normal queue, which is the
		// correct gate for prefer.
	} else {
		ttftThreshold := deadline
		// Pre-flight capacity check: can ANY provider serve this model right
		// now? If not, return 429 immediately rather than queueing for up to
		// 120s. OpenRouter treats 429 as "rate limited" (no uptime penalty) vs
		// 503 which counts as downtime. Fast 429s also preserve our TTFT
		// metrics. Self-route skips this fleet-wide gate — it queues on the
		// owner's machine instead (handled below).
		candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials...)
		if candidateCount == 0 && capacityRejections > 0 {
			if fallbackModel, fallbackCandidates, fallbackRejections, fallbackTooLarge, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasCapacity(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
				candidateCount, capacityRejections, modelTooLarge = fallbackCandidates, fallbackRejections, fallbackTooLarge
				bestTTFT, hasTTFT = fallbackTTFT, fallbackHasTTFT
				if isResponsesAPI {
					providerParsed, err := responsesRequestToChatCompletions(parsed)
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
					rawBody, _ = marshalForwardBody(providerParsed)
				} else {
					rawBody, _ = marshalForwardBody(parsed)
				}
			}
		}
		if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
			// Providers serve this model but none can ever fit it — non-retryable.
			// Surface a clear 503 instead of a 429 the client would retry forever.
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "model_too_large",
				httpStatus:              http.StatusServiceUnavailable,
				keyID:                   keyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  stream,
				estimatedPromptTokens:   estimatedPromptTokens,
				requestedMaxTokens:      requestedMaxTokens,
				requiresVision:          requiresVision,
				hasTools:                hasTools,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q is too large for any currently available provider", publicModel),
				withCode("model_unavailable")))
			return
		}
		if candidateCount == 0 && capacityRejections > 0 {
			// Routing v2 W3: feed the autoscaler the demand the preflight sees.
			s.registry.RecordWarmPoolCapacityReject(model)
			s.triggerWarmPool()
			// Queue-before-shed (default on): providers exist for this model but
			// all are at capacity right now. Rather than an immediate 429, let the
			// request fall through to the normal dispatch+queue path so a slot
			// freeing — or a cold load completing — within the queue window serves
			// it. The dispatch/queue path still returns a 429 when the queue is
			// full or the wait times out (true saturation). The reservation is
			// kept for dispatch.
			if s.queueBeforeShedEnabled() {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_queue_spill"})
			} else {
				// Legacy fast-shed: immediate 429.
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				refundReservation()
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
				s.recordRejection(rejectionInfo{
					r:                       r,
					stage:                   "preflight_capacity",
					reasonCode:              "machine_busy",
					httpStatus:              http.StatusTooManyRequests,
					keyID:                   keyIDFromContext(r.Context()),
					consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
					requestedModel:          publicModel,
					resolvedModel:           model,
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
					retryAfterMs:            retryAfter * 1000,
					params:                  rejectionSamplingParams(parsed),
					servabilityComputed:     true,
					candidateCount:          candidateCount,
					capacityRejections:      capacityRejections,
					modelTooLargeRejections: modelTooLarge,
					bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
				})
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", publicModel, retryAfter),
					withCode("rate_limit_exceeded")))
				return
			}
		}
		if candidateCount == 0 && capacityRejections == 0 && modelTooLarge == 0 {
			// No provider is even structurally eligible right now: the model's
			// whole pool is offline/untrusted, trait-gated (below the tools floor
			// / render-broken), or — the case the shape-keyed breaker introduces —
			// every serving provider is in inference-error cooldown for THIS
			// request shape.
			//
			// Routing v2 W3 cold-dispatch (default on): before shedding, check
			// whether an idle on-disk provider could be WARMED to serve this model
			// (and would then pass admission for these traits). If so, spill the
			// request into the queue instead of 503'ing — the enqueue path kicks
			// the model-swap machinery, and the queued request drains onto the
			// provider once the cold load completes. Note that an idle, fitting
			// cold provider is already a scheduler candidate (slot "unknown" is
			// eligible), so this branch usually only fires for genuinely
			// unservable demand; it is the safety valve for the narrow window
			// where a loadable cold provider is not yet a candidate.
			//
			// Feed the autoscaler the demand regardless of outcome.
			s.registry.RecordWarmPoolCapacityReject(model)
			s.triggerWarmPool()
			if s.coldDispatchEnabled() && s.coldSpillAvailable(model, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials) {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:cold_dispatch_spill"})
				// Fall through to dispatch+queue; reservation kept.
			} else {
				// None of these clear by a slot freeing up, so queueing for up to
				// 120s only adds misleading latency before the same error. Fail
				// fast with a retryable 503 + Retry-After (OpenRouter treats 503
				// as unavailable, not a uptime-penalised error here because the
				// body is explicit). This mirrors the trait fast-fails above for
				// the transient-cooldown case they cannot see.
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				refundReservation()
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:no_eligible_provider"})
				s.recordRejection(rejectionInfo{
					r:                       r,
					stage:                   "preflight_capacity",
					reasonCode:              "no_provider",
					httpStatus:              http.StatusServiceUnavailable,
					keyID:                   keyIDFromContext(r.Context()),
					consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
					requestedModel:          publicModel,
					resolvedModel:           model,
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
					retryAfterMs:            retryAfter * 1000,
					params:                  rejectionSamplingParams(parsed),
					servabilityComputed:     true,
					candidateCount:          candidateCount,
					capacityRejections:      capacityRejections,
					modelTooLargeRejections: modelTooLarge,
					bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
				})
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
					fmt.Sprintf("no provider for model %q is available right now — retry after %ds", publicModel, retryAfter),
					withCode("model_unavailable")))
				return
			}
		}
		if ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold) {
			if !s.ttftHardReject {
				// Soft TTFT gate (default): a provider passed every routing and
				// capacity gate, and pr.MaxTTFTMs is left 0 in soft mode, so the
				// dispatch path serves the best-available provider instead of
				// re-rejecting (P1 fix). Do NOT divert to an older alias build here
				// (P2 fix) — the desired build is routable. A soft-serve over the
				// deadline is still a TTFT near-miss, so feed the autoscaler so it
				// grows warm capacity for this model.
				s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
				s.triggerWarmPool()
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:ttft_soft_served"})
			} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasTTFT(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
				if isResponsesAPI {
					providerParsed, err := responsesRequestToChatCompletions(parsed)
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
					rawBody, _ = marshalForwardBody(providerParsed)
				} else {
					rawBody, _ = marshalForwardBody(parsed)
				}
			} else {
				// Hard TTFT gate, no faster alias: shed with a 429 + Retry-After,
				// and feed the autoscaler a TTFT-miss so warm capacity grows.
				s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
				s.triggerWarmPool()
				retryModel, retryTTFT := fasterTTFTEstimate(model, bestTTFT, fallbackModel, fallbackTTFT, fallbackHasTTFT)
				refundReservation()
				s.recordRejection(rejectionInfo{
					r:                       r,
					stage:                   "routing_ttft",
					reasonCode:              "ttft_too_slow",
					httpStatus:              http.StatusTooManyRequests,
					keyID:                   keyIDFromContext(r.Context()),
					consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
					requestedModel:          publicModel,
					resolvedModel:           model,
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
					params:                  rejectionSamplingParams(parsed),
					servabilityComputed:     true,
					candidateCount:          candidateCount,
					capacityRejections:      capacityRejections,
					modelTooLargeRejections: modelTooLarge,
					bestTTFTMs:              float64(retryTTFT.Milliseconds()),
				})
				s.writeTTFTTooSlow(w, retryModel, publicModel, retryTTFT, ttftThreshold)
				return
			}
		}
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
	// Final cap on the body we'll seal. The read cap (parseInferencePrelude)
	// bounded the request as received, but rawBody has since been re-marshaled at
	// several points — alias resolution, allowlist/routing-field stripping,
	// reasoning_parser + max_tokens injection, Responses→chat lowering, and the
	// alias-capacity fallback above. The coordinator seals this body and sends it
	// as ONE WebSocket frame; a body over the cap produces a frame the provider
	// rejects by tearing down its session and cancelling every unrelated in-flight
	// request (see maxInferenceBodyBytes / CoordinatorClient.maxInboundMessageBytes).
	// This is the single point where rawBody is frozen into dispatchState, so the
	// check here covers every upstream mutation; an oversized request gets a clean
	// 413 instead of disconnecting a provider mid-flight. The reservation is held
	// at this point, so refund before returning.
	if len(rawBody) > maxInferenceBodyBytes {
		refundReservation()
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "validation",
			reasonCode:            "payload_too_large",
			httpStatus:            http.StatusRequestEntityTooLarge,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                stream,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			requestBodyBytes:      len(rawBody),
			params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error",
			fmt.Sprintf("request body exceeds the %d-byte limit", maxInferenceBodyBytes)))
		return
	}

	d := &dispatchState{
		s:                      s,
		w:                      w,
		r:                      r,
		model:                  model,
		publicModel:            publicModel,
		rawBody:                rawBody,
		consumerKey:            consumerKey,
		consumerLocation:       consumerLocation,
		reservedMicroUSD:       reservedMicroUSD,
		tokenAdmission:         tokenAdmission,
		serviceReservation:     serviceReservation,
		estimatedPromptTokens:  estimatedPromptTokens,
		requestedMaxTokens:     requestedMaxTokens,
		requiresVision:         requiresVision,
		hasTools:               hasTools,
		isResponsesAPI:         isResponsesAPI,
		stream:                 stream,
		policy:                 policy,
		allowedProviderSerials: allowedProviderSerials,
		cacheAffinityKey:       cacheAffinityKey,
		timing:                 timing,
		deadline:               deadline,
		speculativeAt:          time.Duration(float64(deadline) * speculativeTimerRatio),
		refundReservation:      refundReservation,
		// Track providers that failed during retry so we don't dispatch to them again.
		excludeProviders: make(map[string]struct{}),
	}
	d.run()
}

// handleStreamingResponseWithFirstChunk streams SSE chunks to the consumer.
// Any firstChunks (held preamble + first content chunk) are written in order
// before reading further chunks from the channel. This allows the dispatch
// loop to "peek" at chunks for retry decisions without losing them.
func (s *Server) handleStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	if pr.IsResponsesAPI {
		s.handleResponsesStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// X-Request-ID is set by the logging middleware to the trace ID. The
	// internal pr.RequestID is the per-attempt provider job UUID and may
	// change across retries — exposing it as X-Request-ID would diverge
	// from the access log. Surface the provider job UUID under its own
	// header for callers who need to correlate to provider-side logs.
	w.Header().Set("X-Inference-Job-ID", pr.RequestID)
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	// Detect Responses API format to skip appending chat-completions-style
	// termination events (SE signature chunk + [DONE]).
	sawResponsesAPI := false

	// The terminal include_usage chunk lacks the reasoning breakdown; we hold its
	// parsed object and re-emit it at stream end with the provider's authoritative
	// reasoning count (CompleteCh) spliced in — matching the non-streaming/Responses
	// paths. Held as a parsed map so it is decoded exactly once. Declared before the
	// first-chunk write because a zero-delta completion (empty/filtered output) can
	// make the include_usage frame the very first chunk.
	var pendingUsage map[string]any

	// The chunk carrying the terminal finish_reason is held the same way: the
	// provider engine reports "stop" even when generation hit the max-tokens
	// bound, so the coordinator re-derives "length" from the authoritative
	// token counts (CompleteCh) before forwarding it.
	var pendingFinish map[string]any

	// Write the chunks that were already consumed during dispatch (held
	// preamble first, then the committing content chunk), each through the
	// same per-chunk special-casing the relay loop below applies.
	for _, firstChunk := range firstChunks {
		if firstChunk == "" || isSSEDoneChunk(firstChunk) {
			continue
		}
		if isResponsesAPIEventChunk(firstChunk) {
			sawResponsesAPI = true
		}
		// A usage-only first chunk (no content/reasoning deltas streamed before it)
		// is still terminal usage — hold it so the reasoning breakdown is spliced in
		// at stream end instead of being emitted raw without reasoning_tokens.
		if obj, isUsage := parseUsageOnlyStreamChunk(firstChunk); !sawResponsesAPI && isUsage {
			pendingUsage = obj
		} else if obj, isFinish := parseFinishStreamChunk(normalizeSSEChunk(firstChunk)); !sawResponsesAPI && isFinish {
			pendingFinish = obj
		} else {
			if !sawResponsesAPI {
				firstChunk = normalizeSSEChunk(firstChunk)
			}
			firstChunk = rewriteChunkModel(firstChunk, pr)
			fmt.Fprintf(w, "%s\n\n", firstChunk)
			flusher.Flush()
		}
	}

	// Use a timer that resets on each chunk so long-running generations
	// (e.g. chain-of-thought models) don't hit a global timeout.
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
						s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
						s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
						errData, _ := json.Marshal(map[string]any{
							"error": map[string]any{
								"message": errMsg.Error,
								"type":    "provider_error",
							},
						})
						fmt.Fprintf(w, "data: %s\n\n", errData)
						flusher.Flush()
						return
					}
				default:
				}
				if s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
					s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_incomplete"})
					s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderIncompleteOutcome(pr))
					fmt.Fprintf(w, "data: {\"error\":{\"message\":\"provider ended without completion\",\"type\":\"provider_error\"}}\n\n")
					flusher.Flush()
					return
				}
				// Channel closed — inference complete.
				s.noteInferenceSuccess(pr)
				// For Responses API streams, the provider already sent
				// "response.completed" as the terminal event. Adding
				// extra chunks would break SDK parsers.
				if !sawResponsesAPI {
					// Emit the held finish/usage chunks with the authoritative token
					// counts (CompleteCh) spliced in: the finish chunk gets its
					// finish_reason corrected to "length" when generation hit the
					// max-tokens bound, and the usage chunk gets the reasoning
					// breakdown. This select runs once, at stream end: the provider's
					// inferenceComplete (which populates CompleteCh) is what ends the
					// stream, so it is effectively already buffered — the timeout is a
					// fallback, not a hot-path wait.
					var usage protocol.UsageInfo
					if pendingUsage != nil || pendingFinish != nil {
						select {
						case u, uok := <-pr.CompleteCh:
							if uok {
								usage = u
							}
						case <-time.After(2 * time.Second):
						case <-r.Context().Done():
						}
					}
					if pendingFinish != nil {
						if out := finalizeFinishChunk(pendingFinish, usage, pr); out != "" {
							fmt.Fprintf(w, "%s\n\n", out)
							flusher.Flush()
						}
					}
					if pendingUsage != nil {
						// Ride the SE signature on the held usage chunk (a complete,
						// well-formed chat.completion.chunk) instead of emitting a
						// separate bare event that strict SDK parsers reject.
						if pr.SESignature != "" {
							pendingUsage["se_signature"] = pr.SESignature
							pendingUsage["response_hash"] = pr.ResponseHash
						}
						if out := finalizeUsageChunk(pendingUsage, usage, pr); out != "" {
							fmt.Fprintf(w, "%s\n\n", out)
							flusher.Flush()
						}
					} else if pr.SESignature != "" {
						// No held usage chunk to ride on: emit the signature as a
						// fully-shaped chat.completion.chunk (id/object/created/model/
						// choices) so strict decoders parse it; the extra fields are
						// additive. It precedes the single [DONE] below.
						sigEvent, _ := json.Marshal(map[string]any{
							"id":            "chatcmpl-" + pr.RequestID,
							"object":        "chat.completion.chunk",
							"created":       time.Now().Unix(),
							"model":         consumerModel(pr),
							"choices":       []any{},
							"se_signature":  pr.SESignature,
							"response_hash": pr.ResponseHash,
						})
						fmt.Fprintf(w, "data: %s\n\n", sigEvent)
						flusher.Flush()
					}
					// Exactly one terminator, after every coordinator-appended event.
					fmt.Fprint(w, "data: [DONE]\n\n")
					flusher.Flush()
				}
				return
			}
			// Every chunk is a liveness signal — re-arm the idle timeout up front,
			// before deciding whether to forward or hold it, so holding the terminal
			// usage chunk still resets the window that bounds the wait for the
			// provider's inference_complete (which closes ChunkCh after billing).
			// One reset covers both the forward and hold paths.
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

			if !sawResponsesAPI {
				if isResponsesAPIEventChunk(chunk) {
					sawResponsesAPI = true
				}
			}
			// Swallow the provider's own "data: [DONE]" terminator. The
			// coordinator appends terminal events of its own (held usage with
			// the reasoning breakdown, SE signature) and then emits exactly ONE
			// [DONE] — forwarding the provider's produced a stream shaped
			// `...usage, [DONE], signature, [DONE]`, and third-party SDKs treat
			// the first [DONE] as final (MacPaw/OpenAI then chokes parsing the
			// signature event).
			if !sawResponsesAPI && isSSEDoneChunk(chunk) {
				continue
			}
			// Hold the terminal usage chunk (chat completions only) so we can splice
			// in the reasoning breakdown at stream end; forwarding it inline would
			// emit it without reasoning_tokens.
			if !sawResponsesAPI {
				if obj, isUsage := parseUsageOnlyStreamChunk(chunk); isUsage {
					pendingUsage = obj
					continue
				}
			}
			if !sawResponsesAPI {
				chunk = normalizeSSEChunk(chunk)
				// Hold the chunk carrying the terminal finish_reason so it can be
				// corrected to "length" against the authoritative token counts at
				// stream end (the provider engine always reports "stop").
				if obj, isFinish := parseFinishStreamChunk(chunk); isFinish {
					pendingFinish = obj
					continue
				}
			}
			chunk = rewriteChunkModel(chunk, pr)
			fmt.Fprintf(w, "%s\n\n", chunk)
			flusher.Flush()

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
			errData, _ := json.Marshal(map[string]any{
				"error": map[string]any{
					"message": errMsg.Error,
					"type":    "provider_error",
				},
			})
			fmt.Fprintf(w, "data: %s\n\n", errData)
			flusher.Flush()
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
			fmt.Fprintf(w, "data: {\"error\":{\"message\":\"request timed out\",\"type\":\"timeout\"}}\n\n")
			flusher.Flush()
			return

		case <-r.Context().Done():
			return
		}
	}
}

func (s *Server) handleResponsesStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "streaming not supported"))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Inference-Job-ID", pr.RequestID)
	w.WriteHeader(http.StatusOK)

	responseID := "resp_" + strings.ReplaceAll(pr.RequestID, "-", "")
	createdAt := time.Now().Unix()
	emitter := newResponsesStreamEmitter(w, flusher, pr, responseID, createdAt)
	emitter.start()

	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			emitter.handleChunk(firstChunk)
		}
	}

	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
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
				return
			}
			emitter.handleChunk(chunk)
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			timer.Reset(inferenceTimeout)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:provider_error"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitProviderErrorOutcome(pr, errMsg))
			emitter.emitError("provider_error", errMsg.Error)
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			s.ddIncr("inference.in_band_error", []string{"model:" + pr.Model, "reason:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, postCommitStreamTimeoutOutcome(pr))
			emitter.emitError("timeout", "request timed out")
			return

		case <-r.Context().Done():
			return
		}
	}
}

// handleNonStreamingResponseWithFirstChunk collects all chunks from the
// provider and assembles them into a single OpenAI-compatible JSON response.
// Any firstChunks (held preamble + first content chunk consumed during
// dispatch) seed the collected chunks in order.
func (s *Server) handleNonStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunks []string) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string
	for _, firstChunk := range firstChunks {
		if firstChunk != "" {
			chunks = append(chunks, firstChunk)
		}
	}

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
						s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
						s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, errMsg))
						statusCode := errMsg.StatusCode
						if statusCode == 0 {
							statusCode = http.StatusBadGateway
						}
						writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
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
									respObj := chatCompletionToResponses(chatResp, consumerModel(pr), pr.SESignature, pr.ResponseHash)
									s.noteInferenceSuccess(pr)
									writeJSON(w, http.StatusOK, respObj)
									return
								}
							} else {
								// Native passthrough (object=="response"): the provider
								// echoed the concrete build id; rewrite it to the public
								// alias so the consumer never sees the quant/build.
								if pr.PublicModel != "" {
									obj["model"] = consumerModel(pr)
								}
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
							s.noteInferenceSuccess(pr)
							writeJSON(w, http.StatusOK, obj)
							return
						}
					}
				}

				// Fallback: SSE delta chunks — reconstruct into response.
				msg := extractMessage(chunks)
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
						resp = buildResponsesResponse(pr.RequestID, consumerModel(pr), msg, usage, pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash)
					} else {
						resp = buildNonStreamingResponse(pr.RequestID, consumerModel(pr), msg, usage, pr.RequestedMaxTokens, pr.SESignature, pr.ResponseHash)
					}
					s.noteInferenceSuccess(pr)
					writeJSON(w, http.StatusOK, resp)
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
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			s.noteInferenceError(pr.ProviderID, pr, errMsg.StatusCode)
			s.updateInferenceRouteOutcomeForPending(pr, preResponseProviderErrorOutcome(pr, errMsg))
			statusCode := errMsg.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusBadGateway
			}
			writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
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
	for _, rawChoice := range choices {
		choice, ok := rawChoice.(map[string]any)
		if !ok {
			continue
		}
		if message, ok := choice["message"].(map[string]any); ok {
			normalizeCompleteMessage(message)
		}
		if delta, ok := choice["delta"].(map[string]any); ok {
			normalizeCompleteMessage(delta)
		}
	}
}

func normalizeCompleteMessage(message map[string]any) {
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
// Some backends (e.g. vllm-mlx) emit "content":null instead of "content":"",
// and include "usage":null which strict parsers (ForgeCode, Codex) reject
// because they expect usage to be either absent or a full object.
func normalizeSSEChunk(chunk string) string {
	line := strings.TrimPrefix(chunk, "data: ")
	// Only trigger the expensive JSON parse for fields we actually fix.
	// "finish_reason":null appears on every chunk but we don't touch it,
	// so checking for generic ":null" causes unnecessary JSON round-trips.
	needsNullFix := strings.Contains(line, `"content":null`) ||
		strings.Contains(line, `"tool_calls":null`) ||
		strings.Contains(line, `"usage":null`) ||
		strings.Contains(line, `"reasoning":null`) ||
		strings.Contains(line, `"reasoning_content":null`) ||
		strings.Contains(line, `"refusal":null`) ||
		strings.Contains(line, `"system_fingerprint":null`)
	needsReasoningDedup := strings.Contains(line, `"reasoning_content"`)
	if !needsNullFix && !needsReasoningDedup {
		return chunk
	}

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
						for _, field := range []string{"content", "reasoning_content", "reasoning", "refusal"} {
							if v, ok := delta[field]; ok && string(v) == "null" {
								delta[field] = json.RawMessage(`""`)
								changed = true
							}
						}
						if v, ok := delta["tool_calls"]; ok && string(v) == "null" {
							delta["tool_calls"] = json.RawMessage(`[]`)
							changed = true
						}
						// Emit BOTH "reasoning" and "reasoning_content" so both
						// AI SDK (reads reasoning_content) and ForgeCode/other
						// clients (reads reasoning) see reasoning tokens.
						if _, hasR := delta["reasoning"]; hasR {
							if _, hasRC := delta["reasoning_content"]; !hasRC {
								// Only reasoning exists — copy to reasoning_content for AI SDK.
								delta["reasoning_content"] = delta["reasoning"]
								changed = true
							}
						} else if rc, hasRC := delta["reasoning_content"]; hasRC {
							// Only reasoning_content exists — add reasoning alias.
							delta["reasoning"] = rc
							changed = true
						}
						if changed {
							choices[i]["delta"], _ = json.Marshal(delta)
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

// extractedMessage holds the reconstructed assistant message from SSE chunks,
// including text content, reasoning, and any tool calls.
type extractedMessage struct {
	Content      string           `json:"content"`
	Reasoning    string           `json:"reasoning,omitempty"`
	ToolCalls    []map[string]any `json:"tool_calls,omitempty"`
	FinishReason string           `json:"-"`
}

// extractMessage parses SSE data lines and reconstructs the full assistant
// message from streaming chunks, including content, reasoning, and tool_calls.
func extractMessage(chunks []string) extractedMessage {
	var contentBuilder strings.Builder
	var reasoningBuilder strings.Builder
	finishReason := ""
	// Tool calls are indexed — accumulate argument fragments by index.
	toolCallMap := map[int]map[string]any{}

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
				Content          string `json:"content"`
				Reasoning        string `json:"reasoning"`
				ReasoningContent string `json:"reasoning_content"`
				ToolCalls        []struct {
					Index    int    `json:"index"`
					ID       string `json:"id,omitempty"`
					Type     string `json:"type,omitempty"`
					Function struct {
						Name      string `json:"name,omitempty"`
						Arguments string `json:"arguments,omitempty"`
					} `json:"function,omitempty"`
				} `json:"tool_calls,omitempty"`
			} `json:"delta"`
			Message struct {
				Content          string `json:"content"`
				Reasoning        string `json:"reasoning"`
				ReasoningContent string `json:"reasoning_content"`
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
			if c.Delta.Reasoning != "" {
				reasoningBuilder.WriteString(c.Delta.Reasoning)
			} else if c.Delta.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Delta.ReasoningContent)
			} else if c.Message.Reasoning != "" {
				reasoningBuilder.WriteString(c.Message.Reasoning)
			} else if c.Message.ReasoningContent != "" {
				reasoningBuilder.WriteString(c.Message.ReasoningContent)
			}
			for _, tc := range c.Delta.ToolCalls {
				existing, ok := toolCallMap[tc.Index]
				if !ok {
					existing = map[string]any{
						"index": tc.Index,
						"function": map[string]any{
							"arguments": "",
						},
					}
					toolCallMap[tc.Index] = existing
				}
				if tc.ID != "" {
					existing["id"] = tc.ID
				}
				if tc.Type != "" {
					existing["type"] = tc.Type
				}
				fn := existing["function"].(map[string]any)
				if tc.Function.Name != "" {
					fn["name"] = tc.Function.Name
				}
				fn["arguments"] = fn["arguments"].(string) + tc.Function.Arguments
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
	msg := extractedMessage{Content: content, Reasoning: reasoning, FinishReason: finishReason}
	if len(toolCallMap) > 0 {
		msg.ToolCalls = make([]map[string]any, 0, len(toolCallMap))
		for i := range len(toolCallMap) {
			if tc, ok := toolCallMap[i]; ok {
				delete(tc, "index")
				msg.ToolCalls = append(msg.ToolCalls, tc)
			}
		}
	}
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

// parseUsageOnlyStreamChunk decodes a terminal include_usage chunk (empty choices
// + a non-null usage object, carrying the final usage and no content delta) and
// returns the parsed object. ok is false for any other chunk. Parsing here once
// lets the caller hold the object and finalize it at stream end without re-parsing.
// isSSEDoneChunk reports whether a provider stream chunk is the SSE
// "data: [DONE]" terminator (with or without the data: prefix). The
// coordinator owns stream termination — provider terminators are swallowed
// so coordinator-appended events (held usage, SE signature) never trail a
// [DONE] that SDKs treat as final.
func isSSEDoneChunk(chunk string) bool {
	line := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(chunk), "data:"))
	return line == "[DONE]"
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

func buildResponsesUsage(promptTokens, completionTokens uint64, reasoningTokens uint64) types.ResponsesUsage {
	return types.ResponsesUsage{
		InputTokens:        int(promptTokens),
		InputTokensDetail:  types.ResponsesUsageDetail{},
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
func finalizeResponsesEnvelope(r *types.ResponsesResponse) {
	if r.IncompleteDetail != nil {
		r.Status = "incomplete"
	} else {
		r.Status = "completed"
	}
	r.ParallelToolCalls = true
	if r.ToolChoice == nil {
		r.ToolChoice = "auto"
	}
	if r.Tools == nil {
		r.Tools = []any{}
	}
	if r.Metadata == nil {
		r.Metadata = map[string]any{}
	}
}

func buildResponsesResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, requestedMax int, seSignature, responseHash string) types.ResponsesResponse {
	reasoningTokens := resolveReasoningTokens(usage, msg.Reasoning)
	finishReason := effectiveFinishReason(msg.FinishReason, len(msg.ToolCalls) > 0, usage, requestedMax)
	resp := types.ResponsesResponse{
		ID:               "resp_" + strings.ReplaceAll(requestID, "-", ""),
		Object:           "response",
		CreatedAt:        time.Now().Unix(),
		Model:            model,
		Output:           appendResponsesOutputItems(nil, requestID, msg),
		Usage:            buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens),
		IncompleteDetail: buildResponsesIncompleteDetails(finishReason),
	}
	finalizeResponsesEnvelope(&resp)
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
	return buildResponsesUsage(uint64(resp.Usage.PromptTokens), uint64(resp.Usage.CompletionTokens), uint64(reasoningTokens))
}

func chatCompletionToResponses(resp types.ChatCompletionResponse, requestedModel, seSignature, responseHash string) types.ResponsesResponse {
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
	finalizeResponsesEnvelope(&r)
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
func hideAliasBuild(hidden map[string]struct{}, catalogByID map[string]store.SupportedModel, buildID string) {
	if buildID == "" {
		return
	}
	if _, inCatalog := catalogByID[buildID]; inCatalog {
		hidden[buildID] = struct{}{}
	}
}

// aliasModelEntries builds the consumer-facing /v1/models entries for active
// public aliases and returns the set of underlying build ids those aliases
// cover (so the caller can hide them from the default listing). The hidden set
// covers EVERY build an alias references — desired, previous, and the retired
// lineage — so a concrete quant build never appears as its own entry once it is
// behind an alias. Each alias entry derives its metadata from its primary build
// — the desired build, or the previous build if the desired one isn't in the
// catalog yet — and aggregates live capacity across the desired and previous
// builds so the alias's routable/warm counts reflect every quant currently
// serving it (retired builds are hide-only and never contribute capacity).
func (s *Server) aliasModelEntries(
	capByModel map[string]*registry.ModelCapacity,
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
) ([]types.ModelEntry, map[string]struct{}) {
	hidden := make(map[string]struct{})
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model registry: failed to list aliases", "error", err)
		return nil, hidden
	}

	entries := make([]types.ModelEntry, 0, len(aliases))
	for _, a := range aliases {
		if !a.Active || a.DesiredBuild == "" {
			continue
		}
		// A consumer must only ever see the alias, never a concrete build behind
		// it. Hide EVERY build this alias references — desired, previous, AND the
		// retired lineage — from the standalone listing, even if the alias itself
		// isn't advertisable right now. (Capacity below aggregates only the
		// routable desired/previous members; retired builds are hide-only.)
		hideAliasBuild(hidden, catalogByID, a.DesiredBuild)
		hideAliasBuild(hidden, catalogByID, a.PreviousBuild)
		for _, b := range a.RetiredBuilds {
			hideAliasBuild(hidden, catalogByID, b)
		}
		// Primary build = the desired build when it's in the catalog, else the
		// previous build (so the alias keeps a real entry while the desired build
		// is mid-registration). An alias whose builds are all out of catalog
		// resolves to nothing and must not be advertised (it would 503).
		members := make([]string, 0, 2)
		desiredInCatalog := false
		if _, ok := catalogByID[a.DesiredBuild]; ok {
			members = append(members, a.DesiredBuild)
			desiredInCatalog = true
		}
		previousInCatalog := false
		if a.PreviousBuild != "" {
			if _, ok := catalogByID[a.PreviousBuild]; ok {
				members = append(members, a.PreviousBuild)
				previousInCatalog = true
			}
		}
		var primary string
		switch {
		case desiredInCatalog:
			primary = a.DesiredBuild
		case previousInCatalog:
			primary = a.PreviousBuild
		default:
			// No in-catalog build backs this alias — don't advertise it.
			continue
		}

		routable, warm := 0, 0
		canAccept := false
		for _, b := range members {
			if cap, ok := capByModel[b]; ok {
				routable += cap.RoutableProviders
				warm += cap.WarmProviders
				canAccept = canAccept || cap.CanAccept
			}
		}

		cm := catalogByID[primary]
		reg, hasReg := registryByID[primary]
		displayName := a.DisplayName
		if displayName == "" {
			displayName = cm.DisplayName
		}
		metadata := types.ModelMetadata{
			ModelType:         cm.ModelType,
			Quantization:      "", // an alias spans quants; omit the per-build quant
			DisplayName:       displayName,
			RoutableProviders: routable,
			WarmProviders:     warm,
			CanAccept:         canAccept,
		}
		entry := types.ModelEntry{
			ID:       a.AliasID,
			Object:   "model",
			OwnedBy:  "eigeninference",
			Name:     displayName,
			Metadata: metadata,
		}
		// Pricing / context / features come from the primary build's registry
		// entry. Quantization is intentionally left blank on the alias.
		primaryQuant := ""
		if hasReg {
			primaryQuant = reg.Quantization
		}
		s.openRouterModelFieldsFor(primary, primaryQuant, reg, hasReg).applyToModelEntry(&entry)
		entry.Quantization = ""
		var caps []string
		if hasReg {
			caps = reg.Capabilities
		}
		entry.InputModalities, entry.OutputModalities = deriveModalities(cm.ModelType, caps)
		entries = append(entries, entry)
	}
	return entries, hidden
}

// listModelEntries assembles the consumer-facing model entries shared by
// GET /v1/models and GET /v1/models/{id}. includeBuilds also lists the raw
// quant builds hidden behind public aliases (ops/debug).
func (s *Server) listModelEntries(includeBuilds bool) ([]types.ModelEntry, error) {
	models := s.registry.ListModels()

	// Build a lookup of capacity data keyed by model ID.
	capacities := s.registry.ModelCapacitySnapshot()
	capByModel := make(map[string]*registry.ModelCapacity, len(capacities))
	for i := range capacities {
		capByModel[capacities[i].ModelID] = &capacities[i]
	}

	// Filter to only show models from the active catalog, and capture the richer
	// registry entries used to populate the OpenRouter provider fields. These
	// lookups are shared with the dedicated /v1/models/openrouter feed.
	catalogByID, registryByID, err := s.activeCatalogLookups()
	if err != nil {
		return nil, err
	}

	// Public aliases are the consumer-facing model names; their underlying
	// quant builds are hidden by default so consumers never see the quant.
	aliasEntries, hiddenBuilds := s.aliasModelEntries(capByModel, catalogByID, registryByID)

	data := make([]types.ModelEntry, 0, len(models)+len(aliasEntries))
	data = append(data, aliasEntries...)
	for _, m := range models {
		cm, inCatalog := catalogByID[m.ID]
		if len(catalogByID) > 0 && !inCatalog {
			continue
		}
		if _, hidden := hiddenBuilds[m.ID]; hidden && !includeBuilds {
			continue
		}
		metadata := types.ModelMetadata{
			ModelType:         m.ModelType,
			Quantization:      m.Quantization,
			ProviderCount:     m.Providers,
			AttestedProviders: m.AttestedProviders,
			TrustLevel:        string(m.TrustLevel),
		}
		// Add capacity fields from live snapshot.
		if cap, ok := capByModel[m.ID]; ok {
			metadata.RoutableProviders = cap.RoutableProviders
			metadata.WarmProviders = cap.WarmProviders
			metadata.CanAccept = cap.CanAccept
		} else {
			metadata.RoutableProviders = 0
			metadata.WarmProviders = 0
			metadata.CanAccept = false
		}
		if m.Attestation != nil {
			metadata.Attestation = &types.ModelAttestation{
				SecureEnclave: m.Attestation.SecureEnclave,
				SIPEnabled:    m.Attestation.SIPEnabled,
				SecureBoot:    m.Attestation.SecureBoot,
			}
		}
		if inCatalog && cm.DisplayName != "" {
			metadata.DisplayName = cm.DisplayName
		}

		entry := types.ModelEntry{
			ID:            m.ID,
			Object:        "model",
			Created:       0,
			OwnedBy:       "eigeninference",
			Name:          metadata.DisplayName,
			HuggingFaceID: m.ID, // model IDs are HuggingFace paths
			Metadata:      metadata,
		}

		// OpenRouter provider fields (quantization, per-token pricing, sampling
		// params, and registry-sourced metadata), shared with the dedicated
		// /v1/models/openrouter feed.
		reg, hasReg := registryByID[m.ID]
		s.openRouterModelFieldsFor(m.ID, m.Quantization, reg, hasReg).applyToModelEntry(&entry)

		// Modalities are derived from the model's capabilities (text by default).
		var caps []string
		if hasReg {
			caps = reg.Capabilities
		}
		entry.InputModalities, entry.OutputModalities = deriveModalities(m.ModelType, caps)

		data = append(data, entry)
	}

	return data, nil
}

func (s *Server) handleListModels(w http.ResponseWriter, r *http.Request) {
	// Pass ?include_builds=1 (ops/debug) to also list the raw quant builds.
	data, err := s.listModelEntries(r.URL.Query().Get("include_builds") == "1")
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}

	writeJSON(w, http.StatusOK, types.ModelListResponse{
		Object: "list",
		Data:   data,
	})
}

// handleGetModel handles GET /v1/models/{id...} — the OpenAI "retrieve model"
// endpoint. Model IDs may contain slashes (HuggingFace paths), hence the
// wildcard path segment. Hidden quant builds are retrievable by their exact
// id, matching the behavior of requesting one for inference.
func (s *Server) handleGetModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	data, err := s.listModelEntries(true)
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}
	for _, entry := range data {
		if entry.ID == id {
			writeJSON(w, http.StatusOK, entry)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
		fmt.Sprintf("model %q not found", id), withParam("model")))
}

// handleCreateKey handles POST /v1/auth/keys — creates a new consumer API key.
// Requires Privy authentication. The key is linked to the user's account so
// requests made with the key are billed to the same account.
func (s *Server) handleCreateKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	key, err := s.store.CreateKeyForAccount(user.AccountID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create key"))
		return
	}
	writeJSON(w, http.StatusOK, types.CreateKeyResponse{
		APIKey:    key,
		AccountID: user.AccountID,
	})
}

// handleRevokeKey handles DELETE /v1/auth/keys — revokes an API key.
// The caller must own the key (same account). Requires Privy auth so a
// compromised API key cannot revoke legitimate keys.
func (s *Server) handleRevokeKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}

	var body struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Key == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "provide {\"key\": \"sk-db-...\"}"))
		return
	}

	owner := s.store.GetKeyAccount(body.Key)
	if owner != user.AccountID {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "you can only revoke your own keys"))
		return
	}

	if !s.store.RevokeKey(body.Key) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found or already revoked"))
		return
	}
	s.invalidateAPIKeyCache(body.Key)

	writeJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}

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

// apiKeyToResponse projects a stored key into its masked API representation,
// computing the current-window spend and remaining budget.
func (s *Server) apiKeyToResponse(k *store.APIKey) types.APIKeyResponse {
	resp := types.APIKeyResponse{
		ID:            k.ID,
		Name:          k.Name,
		Label:         k.Label,
		Disabled:      k.Disabled,
		LimitReset:    store.NormalizeResetWindow(k.LimitReset),
		RPMLimit:      k.RPMLimit,
		ITPMLimit:     k.ITPMLimit,
		OTPMLimit:     k.OTPMLimit,
		AllowedModels: k.AllowedModels,
		SelfRouteOnly: k.SelfRouteOnly,
		ExpiresAt:     k.ExpiresAt,
		CreatedAt:     k.CreatedAt,
		LastUsedAt:    k.LastUsedAt,
	}
	since := store.KeySpendWindowStart(resp.LimitReset, time.Now())
	spent := s.store.KeySpendSince(k.ID, since)
	resp.UsageUSD = microToUSD(spent)
	if k.LimitMicroUSD != nil {
		limitUSD := microToUSD(*k.LimitMicroUSD)
		resp.LimitUSD = &limitUSD
		remaining := *k.LimitMicroUSD - spent
		if remaining < 0 {
			remaining = 0
		}
		remUSD := microToUSD(remaining)
		resp.RemainingUSD = &remUSD
	}
	return resp
}

// validateKeyLimitInputs sanity-checks user-supplied limit values. Returns a
// human-readable error string (empty when valid).
func validateKeyLimitInputs(reset string, limitUSD *float64, rpm, itpm, otpm *int64, expiresAt *time.Time) string {
	switch reset {
	case "", store.KeyResetNone, store.KeyResetDaily, store.KeyResetWeekly, store.KeyResetMonthly:
	default:
		return "limit_reset must be one of: none, daily, weekly, monthly"
	}
	if limitUSD != nil && *limitUSD < 0 {
		return "limit_usd must be >= 0"
	}
	if rpm != nil && *rpm < 0 {
		return "rpm_limit must be >= 0"
	}
	if itpm != nil && *itpm < 0 {
		return "itpm_limit must be >= 0"
	}
	if otpm != nil && *otpm < 0 {
		return "otpm_limit must be >= 0"
	}
	if expiresAt != nil && !expiresAt.IsZero() && expiresAt.Before(time.Now()) {
		return "expires_at must be in the future"
	}
	return ""
}

// keyModelAllowed returns false when the calling key restricts models via an
// allow-list that does not include the requested model. Account-scoped/legacy
// keys (no key in context) and keys without an allow-list always pass.
func (s *Server) keyModelAllowed(ctx context.Context, model string) bool {
	k := apiKeyFromContext(ctx)
	if k == nil || len(k.AllowedModels) == 0 {
		return true
	}
	for _, m := range k.AllowedModels {
		if m == model {
			return true
		}
	}
	return false
}

// checkKeySpendCap reports whether charging additionalMicroUSD to the calling
// key would exceed its per-key spend cap in the current window. It returns
// (message, ok); ok=false means the request must be rejected with 402. The
// per-account balance ledger is still the hard atomic ceiling — this is the
// soft, per-key sub-cap, enforced against settled usage (so concurrent
// in-flight requests are eventually-consistent, never over the account balance).
func (s *Server) checkKeySpendCap(ctx context.Context, additionalMicroUSD int64) (string, bool) {
	k := apiKeyFromContext(ctx)
	if k == nil || k.ID == "" || k.LimitMicroUSD == nil {
		return "", true
	}
	since := store.KeySpendWindowStart(k.LimitReset, time.Now())
	spent := s.store.KeySpendSince(k.ID, since)
	if spent+additionalMicroUSD > *k.LimitMicroUSD {
		window := store.NormalizeResetWindow(k.LimitReset)
		if window == store.KeyResetNone {
			window = "total"
		}
		return fmt.Sprintf("API key spend limit reached (%s cap $%.2f, used $%.2f) — raise this key's limit or use another key",
			window, microToUSD(*k.LimitMicroUSD), microToUSD(spent)), false
	}
	return "", true
}

// handleListAPIKeys handles GET /v1/keys — lists the caller's keys (masked).
func (s *Server) handleListAPIKeys(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	keys, err := s.store.ListAPIKeys(user.AccountID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to list keys"))
		return
	}
	out := make([]types.APIKeyResponse, 0, len(keys))
	for i := range keys {
		out = append(out, s.apiKeyToResponse(&keys[i]))
	}
	writeJSON(w, http.StatusOK, types.APIKeyListResponse{Object: "list", Data: out})
}

// handleCreateAPIKey handles POST /v1/keys — mints a new named, optionally
// limited key. The raw secret is returned exactly once.
func (s *Server) handleCreateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error",
			"API key creation requires a Privy account — authenticate with a Privy access token"))
		return
	}

	var req createAPIKeyRequest
	if r.Body != nil {
		// A missing/empty body is allowed (creates a default unnamed key).
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "invalid JSON body"))
			return
		}
	}
	if msg := validateKeyLimitInputs(req.LimitReset, req.LimitUSD, req.RPMLimit, req.ITPMLimit, req.OTPMLimit, req.ExpiresAt); msg != "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", msg))
		return
	}

	opts := store.APIKeyCreate{
		Name:          strings.TrimSpace(req.Name),
		LimitReset:    store.NormalizeResetWindow(req.LimitReset),
		RPMLimit:      req.RPMLimit,
		ITPMLimit:     req.ITPMLimit,
		OTPMLimit:     req.OTPMLimit,
		AllowedModels: req.AllowedModels,
		SelfRouteOnly: req.SelfRouteOnly,
		ExpiresAt:     req.ExpiresAt,
	}
	if req.LimitUSD != nil {
		m := usdToMicro(*req.LimitUSD)
		opts.LimitMicroUSD = &m
	}

	raw, rec, err := s.store.CreateAPIKey(user.AccountID, opts)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create key"))
		return
	}
	writeJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}

// handleGetAPIKey handles GET /v1/keys/{id}.
func (s *Server) handleGetAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	k, err := s.store.GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}
	writeJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// handleGetCallingKey handles GET /v1/key — returns the metadata for the API
// key used to authenticate the request (OpenRouter parity).
func (s *Server) handleGetCallingKey(w http.ResponseWriter, r *http.Request) {
	k := apiKeyFromContext(r.Context())
	if k == nil || k.ID == "" {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found",
			"no key metadata — this endpoint requires API key authentication"))
		return
	}
	writeJSON(w, http.StatusOK, s.apiKeyToResponse(k))
}

// handleUpdateAPIKey handles PATCH /v1/keys/{id} — sparse update of a key's
// name, disabled flag, limits, reset window, expiry, and model allow-list.
func (s *Server) handleUpdateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	existing, err := s.store.GetAPIKeyByID(user.AccountID, id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}

	// Decode into a presence map so we can distinguish "field omitted" (leave
	// unchanged) from "field set to null" (clear the limit).
	var patch map[string]json.RawMessage
	if err := json.NewDecoder(r.Body).Decode(&patch); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", "invalid JSON body"))
		return
	}
	if msg := applyKeyPatch(existing, patch); msg != "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", msg))
		return
	}
	if msg := validateKeyLimitInputs(existing.LimitReset, nil, existing.RPMLimit, existing.ITPMLimit, existing.OTPMLimit, existing.ExpiresAt); msg != "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("bad_request", msg))
		return
	}

	// Bump the auth-cache generation before AND after the mutation so a
	// concurrent request cannot keep authenticating with a stale (e.g.
	// just-disabled) cached record.
	s.invalidateAllAPIKeyCache()
	updated, err := s.store.UpdateAPIKey(user.AccountID, id, *existing)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to update key"))
		return
	}
	s.invalidateAllAPIKeyCache()
	writeJSON(w, http.StatusOK, s.apiKeyToResponse(updated))
}

// applyKeyPatch merges a presence-aware PATCH body into an existing key record.
// Returns a human-readable error string on invalid input (empty when ok).
func applyKeyPatch(k *store.APIKey, patch map[string]json.RawMessage) string {
	if raw, ok := patch["name"]; ok {
		var name string
		if err := json.Unmarshal(raw, &name); err != nil {
			return "invalid value for name"
		}
		k.Name = strings.TrimSpace(name)
	}
	if raw, ok := patch["disabled"]; ok {
		var disabled bool
		if err := json.Unmarshal(raw, &disabled); err != nil {
			return "invalid value for disabled"
		}
		k.Disabled = disabled
	}
	if raw, ok := patch["limit_reset"]; ok {
		var reset string
		if err := json.Unmarshal(raw, &reset); err != nil {
			return "invalid value for limit_reset"
		}
		k.LimitReset = store.NormalizeResetWindow(reset)
	}
	if raw, ok := patch["limit_usd"]; ok {
		if string(raw) == "null" {
			k.LimitMicroUSD = nil
		} else {
			var usd float64
			if err := json.Unmarshal(raw, &usd); err != nil {
				return "invalid value for limit_usd"
			}
			if usd < 0 {
				return "limit_usd must be >= 0"
			}
			m := usdToMicro(usd)
			k.LimitMicroUSD = &m
		}
	}
	if raw, ok := patch["allowed_models"]; ok {
		if string(raw) == "null" {
			k.AllowedModels = nil
		} else {
			var models []string
			if err := json.Unmarshal(raw, &models); err != nil {
				return "invalid value for allowed_models"
			}
			k.AllowedModels = models
		}
	}
	if raw, ok := patch["self_route_only"]; ok {
		var v bool
		if err := json.Unmarshal(raw, &v); err != nil {
			return "invalid value for self_route_only"
		}
		k.SelfRouteOnly = v
	}
	for field, dst := range map[string]**int64{
		"rpm_limit":  &k.RPMLimit,
		"itpm_limit": &k.ITPMLimit,
		"otpm_limit": &k.OTPMLimit,
	} {
		if raw, ok := patch[field]; ok {
			if string(raw) == "null" {
				*dst = nil
			} else {
				var v int64
				if err := json.Unmarshal(raw, &v); err != nil {
					return "invalid value for " + field
				}
				*dst = &v
			}
		}
	}
	if raw, ok := patch["expires_at"]; ok {
		if string(raw) == "null" {
			k.ExpiresAt = nil
		} else {
			var t time.Time
			if err := json.Unmarshal(raw, &t); err != nil {
				return "invalid value for expires_at (use RFC 3339)"
			}
			k.ExpiresAt = &t
		}
	}
	return ""
}

// handleDeleteAPIKey handles DELETE /v1/keys/{id} — permanently deletes a key.
func (s *Server) handleDeleteAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	s.invalidateAllAPIKeyCache()
	if err := s.store.RevokeAPIKeyByID(user.AccountID, id); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}
	s.invalidateAllAPIKeyCache()
	writeJSON(w, http.StatusOK, types.RevokeKeyResponse{Status: "revoked"})
}

// handleRotateAPIKey handles POST /v1/keys/{id}/rotate — mints a fresh secret
// carrying the same limits and metadata, then deletes the old key. The new
// secret is returned exactly once.
func (s *Server) handleRotateAPIKey(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	id := r.PathValue("id")
	// Bump the auth-cache generation before AND after the mutation so the old
	// secret stops authenticating the instant rotation commits.
	s.invalidateAllAPIKeyCache()
	raw, rec, err := s.store.RotateAPIKey(user.AccountID, id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "key not found"))
		return
	}
	s.invalidateAllAPIKeyCache()
	writeJSON(w, http.StatusOK, types.CreateAPIKeyResponse{
		Key:  raw,
		Data: s.apiKeyToResponse(rec),
	})
}

// handleHealth handles GET /health.
// Returns the coordinator's status and the number of connected providers.
// This endpoint does not require authentication.
func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, types.HealthResponse{
		Status:      "ok",
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
	const cacheKey = "api_version:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	var resp types.VersionResponse
	// Try release table first.
	if release := s.store.GetLatestRelease("macos-arm64"); release != nil {
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
	s.readCache.Set(cacheKey, body, time.Minute)
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

// writeJSON serializes v as JSON and writes it to the response with the
// given HTTP status code. Sets Content-Type to application/json.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// handleCompletions handles POST /v1/completions.
// Proxies OpenAI-compatible text completions to the provider's vllm-mlx server.
func (s *Server) handleCompletions(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/completions")
}

// handleAnthropicMessages handles POST /v1/messages.
// Proxies Anthropic-compatible messages API to the provider's vllm-mlx server.
func (s *Server) handleAnthropicMessages(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/messages")
}

// handleGenericInference is the shared dispatch for completions and Anthropic endpoints.
// It reads the raw request body, extracts model/stream, sets the endpoint field,
// and reuses the same E2E encryption + provider routing as chat completions.
func (s *Server) handleGenericInference(w http.ResponseWriter, r *http.Request, endpoint string) {
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}

	// Shared prelude: read body, normalize tool schemas (Anthropic /v1/messages
	// bodies carry a top-level "tools" array too; the provider body is rebuilt
	// from parsed below, so normalizing before the unmarshal covers it), parse,
	// require a model, enforce the per-key model allowlist.
	prelude, ok := s.parseInferencePrelude(w, r)
	if !ok {
		return
	}
	rawBody := prelude.rawBody
	parsed := prelude.parsed
	model := prelude.model

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "bad_param",
			httpStatus:      http.StatusBadRequest,
			keyID:           keyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist {
		stripProviderRoutingFields(parsed)
	}

	// "Use my own machine, for free" opt-in (see handleChatCompletions).
	policy := s.resolveSelfRoutePolicy(r)

	// Resolve a public alias to a concrete build id, constraint-aware (after
	// allowlist/self-route are known). resolveRequestedModel rewrites
	// parsed["model"] to the build; this handler builds the provider body fresh
	// from `parsed` (inferenceBody below), so rawBody isn't threaded here.
	buildModel, publicModel, _, ok := s.resolveRequestedModel(parsed, rawBody, model, allowedProviderSerials, policy)
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
	cacheAffinityKey := requestCacheAffinityKey(parsed)

	if !s.registry.IsModelInCatalog(model) {
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
	requiresVision := detectMediaRequirement(parsed)
	hasTools := requestHasTools(parsed)
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		false, policy, allowedProviderSerials) {
		return
	}

	// Completions and Anthropic messages both use the max_tokens field (never
	// max_output_tokens, which is Responses API only). Inject a default if
	// unset so the pre-flight reservation bounds the generation.
	genericMaxOutput := defaultMaxOutputTokens
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil && rec.MaxOutputLength > 0 {
		genericMaxOutput = rec.MaxOutputLength
	}
	ensureMaxTokensBound(parsed, false, genericMaxOutput)

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	genericDeadline := ttftDeadline(estimatedPromptTokens)
	timing.ParsedAt = time.Now()

	// Inject the endpoint so the provider knows which local path to forward to.
	parsed["endpoint"] = endpoint

	// Per-account token rate limiting (ITPM/OTPM), before the reservation.
	tokenAdmission, ok := s.applyTokenRateLimitWithAdmission(w, r, estimatedPromptTokens, requestedMaxTokens)
	if !ok {
		return
	}

	// Pre-flight balance reservation — same worst-case-cost reservation as
	// handleChatCompletions, using the byte-length upper bound for prompt
	// tokens so the reservation always covers actual cost.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)
	var reservedMicroUSD int64
	serviceReservation := false
	// Self-route is free: skip the reservation and per-key spend cap.
	if s.billing != nil && !policy.enabled {
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation.
		if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "balance",
				reasonCode:            "insufficient_quota",
				httpStatus:            http.StatusPaymentRequired,
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
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
			return
		}
		var err error
		serviceReservation, err = s.reserveInitialBalance(consumerKey, model, reservedMicroUSD)
		if err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.recordRejection(rejectionInfo{
					r:                     r,
					stage:                 "balance",
					reasonCode:            "insufficient_funds",
					httpStatus:            http.StatusPaymentRequired,
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
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				s.writeServiceUnavailable(w, model)
			}
			return
		}
	}
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			s.releaseInitialReservation(consumerKey, model, reservedMicroUSD, serviceReservation)
		}
	}
	timing.ReservedAt = time.Now()
	rejectionForGeneric := func(stage, reason string, status, retryAfterMs int) rejectionInfo {
		return rejectionInfo{
			r:                     r,
			stage:                 stage,
			reasonCode:            reason,
			httpStatus:            status,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKey),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                stream,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			selfRouteOnly:         policy.enabled,
			preferOwner:           policy.prefer,
			params:                rejectionSamplingParams(parsed),
			retryAfterMs:          retryAfterMs,
		}
	}
	rejectionForGenericWithDecision := func(stage, reason string, status, retryAfterMs int, decision registry.RoutingDecision) rejectionInfo {
		info := rejectionForGeneric(stage, reason, status, retryAfterMs)
		info.servabilityComputed = true
		info.candidateCount = decision.CandidateCount
		info.capacityRejections = decision.CapacityRejections
		info.modelTooLargeRejections = decision.ModelTooLargeRejections
		info.visionRejections = decision.VisionRejections
		info.bestTTFTMs = decision.BestTTFTMs
		return info
	}

	// Self-route pre-flight (precise errors, no paid fallback); otherwise the
	// fleet-wide capacity 429 (same logic as handleChatCompletions).
	if policy.enabled {
		if s.selfRouteUnavailable(w, r, policy.ownerAccountID, model) {
			refundReservation()
			return
		}
	} else if policy.prefer {
		// Prefer mode skips the public fleet pre-flight (no owner-trust
		// relaxation there); owned-first dispatch + paid fallback + queue gate it.
	} else {
		candidateCount, capacityRejections, modelTooLarge, bestTTFT, hasTTFT := s.registry.QuickCapacityCheckWithTTFTForRequest(model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials...)
		if candidateCount == 0 && capacityRejections > 0 {
			if fallbackModel, fallbackCandidates, fallbackRejections, fallbackTooLarge, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasCapacity(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
				candidateCount, capacityRejections, modelTooLarge = fallbackCandidates, fallbackRejections, fallbackTooLarge
				bestTTFT, hasTTFT = fallbackTTFT, fallbackHasTTFT
			}
		}
		if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
			s.recordRejection(rejectionInfo{
				r:                       r,
				stage:                   "preflight_capacity",
				reasonCode:              "model_too_large",
				httpStatus:              http.StatusServiceUnavailable,
				keyID:                   keyIDFromContext(r.Context()),
				consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
				requestedModel:          publicModel,
				resolvedModel:           model,
				stream:                  stream,
				estimatedPromptTokens:   estimatedPromptTokens,
				requestedMaxTokens:      requestedMaxTokens,
				requiresVision:          requiresVision,
				hasTools:                hasTools,
				params:                  rejectionSamplingParams(parsed),
				servabilityComputed:     true,
				candidateCount:          candidateCount,
				capacityRejections:      capacityRejections,
				modelTooLargeRejections: modelTooLarge,
				bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
			})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q is too large for any currently available provider", publicModel),
				withCode("model_unavailable")))
			return
		}
		if candidateCount == 0 && capacityRejections > 0 {
			// Routing v2 W3: feed the autoscaler the demand the preflight sees.
			s.registry.RecordWarmPoolCapacityReject(model)
			s.triggerWarmPool()
			// Queue-before-shed (default on): all providers for this model are at
			// capacity right now. Fall through to the dispatch+queue path so a slot
			// freeing — or a cold load completing — within the queue window serves
			// it; the queue path still 429s on a full queue or wait timeout.
			if s.queueBeforeShedEnabled() {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_queue_spill"})
			} else {
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				refundReservation()
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
				s.recordRejection(rejectionInfo{
					r:                       r,
					stage:                   "preflight_capacity",
					reasonCode:              "machine_busy",
					httpStatus:              http.StatusTooManyRequests,
					keyID:                   keyIDFromContext(r.Context()),
					consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
					requestedModel:          publicModel,
					resolvedModel:           model,
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
					retryAfterMs:            retryAfter * 1000,
					params:                  rejectionSamplingParams(parsed),
					servabilityComputed:     true,
					candidateCount:          candidateCount,
					capacityRejections:      capacityRejections,
					modelTooLargeRejections: modelTooLarge,
					bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
				})
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", publicModel, retryAfter),
					withCode("rate_limit_exceeded")))
				return
			}
		}
		if candidateCount == 0 && capacityRejections == 0 && modelTooLarge == 0 {
			// No structurally-eligible provider right now (offline, trait-gated,
			// or shape-cooled by the inference-error breaker).
			//
			// Routing v2 W3 cold-dispatch (default on): if an idle on-disk provider
			// could be warmed to serve this model (and would pass admission for
			// these traits), spill into the queue instead of 503'ing — the enqueue
			// path kicks the model-swap machinery and the queued request drains
			// onto the provider once the cold load completes. Feed the autoscaler
			// the demand regardless of outcome.
			s.registry.RecordWarmPoolCapacityReject(model)
			s.triggerWarmPool()
			if s.coldDispatchEnabled() && s.coldSpillAvailable(model, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials) {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:cold_dispatch_spill"})
				// Fall through to dispatch+queue; reservation kept.
			} else {
				// Queueing cannot help — fail fast with a retryable 503 instead of
				// a 120s queue. Mirrors the chat-completions preflight.
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				refundReservation()
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:no_eligible_provider"})
				s.recordRejection(rejectionInfo{
					r:                       r,
					stage:                   "preflight_capacity",
					reasonCode:              "no_provider",
					httpStatus:              http.StatusServiceUnavailable,
					keyID:                   keyIDFromContext(r.Context()),
					consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
					requestedModel:          publicModel,
					resolvedModel:           model,
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
					retryAfterMs:            retryAfter * 1000,
					params:                  rejectionSamplingParams(parsed),
					servabilityComputed:     true,
					candidateCount:          candidateCount,
					capacityRejections:      capacityRejections,
					modelTooLargeRejections: modelTooLarge,
					bestTTFTMs:              ttftMsForRejection(bestTTFT, hasTTFT),
				})
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
					fmt.Sprintf("no provider for model %q is available right now — retry after %ds", publicModel, retryAfter),
					withCode("model_unavailable")))
				return
			}
		}
		ttftThreshold := genericDeadline
		if ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold) {
			if !s.ttftHardReject {
				// Soft TTFT gate (default): serve the best-available provider
				// (MaxTTFTMs is 0 in soft mode — P1 fix); do not divert to an older
				// alias build (P2 fix). Feed the autoscaler a near-miss to grow
				// warm capacity for this model.
				s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
				s.triggerWarmPool()
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:ttft_soft_served"})
			} else if fallbackModel, _, _, _, fallbackTTFT, fallbackHasTTFT, switched := s.maybeFallbackAliasTTFT(parsed, publicModel, model, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, registry.RequestTraits{HasTools: hasTools}, requiresVision, allowedProviderSerials); switched {
				model = fallbackModel
			} else {
				// Hard TTFT gate, no faster alias: 429 + Retry-After, and feed the
				// autoscaler a TTFT-miss so warm capacity grows.
				s.registry.RecordWarmPoolTTFTMiss(model, ttftThreshold)
				s.triggerWarmPool()
				retryModel, retryTTFT := fasterTTFTEstimate(model, bestTTFT, fallbackModel, fallbackTTFT, fallbackHasTTFT)
				refundReservation()
				s.recordRejection(rejectionInfo{
					r:                       r,
					stage:                   "routing_ttft",
					reasonCode:              "ttft_too_slow",
					httpStatus:              http.StatusTooManyRequests,
					keyID:                   keyIDFromContext(r.Context()),
					consumerKeyHash:         store.HashKey(consumerKeyFromContext(r.Context())),
					requestedModel:          publicModel,
					resolvedModel:           model,
					stream:                  stream,
					estimatedPromptTokens:   estimatedPromptTokens,
					requestedMaxTokens:      requestedMaxTokens,
					requiresVision:          requiresVision,
					hasTools:                hasTools,
					params:                  rejectionSamplingParams(parsed),
					servabilityComputed:     true,
					candidateCount:          candidateCount,
					capacityRejections:      capacityRejections,
					modelTooLargeRejections: modelTooLarge,
					bestTTFTMs:              float64(retryTTFT.Milliseconds()),
				})
				s.writeTTFTTooSlow(w, retryModel, publicModel, retryTTFT, ttftThreshold)
				return
			}
		}
	}

	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		PublicModel:            publicModel,
		ConsumerKey:            consumerKey,
		KeyID:                  keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:          keyLimitResetFromContext(r.Context()),
		ConsumerLocation:       consumerLocation,
		AllowedProviderSerials: allowedProviderSerials,
		SelfRouteOnly:          policy.enabled,
		PreferOwner:            policy.prefer,
		OwnerAccountID:         policy.ownerAccountID,
		FreeSelfRoute:          policy.enabled,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequiresVision:         requiresVision,
		CacheAffinityKey:       cacheAffinityKey,
		// Single-attempt path: no retry loop, so no AvoidVersion to thread.
		Traits:               registry.RequestTraits{HasTools: hasTools},
		RequestedMaxTokens:   requestedMaxTokens,
		TokenAdmission:       tokenAdmission,
		ReservedMicroUSD:     reservedMicroUSD,
		BaseReservedMicroUSD: reservedMicroUSD,
		ServiceReservation:   serviceReservation,
		AcceptedCh:           make(chan struct{}, 1),
		ChunkCh:              make(chan string, chunkBufferSize),
		CompleteCh:           make(chan protocol.UsageInfo, 1),
		ErrorCh:              make(chan protocol.InferenceErrorMessage, 1),
		Timing:               timing,
	}

	// Public inference routes (not self-route / prefer-owner) enforce the
	// OpenRouter TTFT ceiling inside the scheduler. This makes the preflight
	// check authoritative: the router cannot select a provider whose estimated
	// TTFT is above the threshold.
	// Routing v2 (P1 fix): enforce the TTFT ceiling only in HARD mode; soft mode
	// leaves MaxTTFTMs 0 so dispatch serves the best-available provider.
	if !policy.enabled && !policy.prefer && s.ttftHardReject {
		pr.MaxTTFTMs = float64(genericDeadline.Milliseconds())
	}
	// Routing v2 W2: soft per-request decode floor (0 = off).
	pr.MinDecodeTPS = s.minDecodeTPS

	// refundExtra credits back the provider-specific surcharge that
	// reserveAdditionalForProvider may have added on top of the base
	// reservation. Without this, failing after the extra charge leaks
	// the difference between pr.ReservedMicroUSD and the original
	// reservedMicroUSD.
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

	var provider *registry.Provider
	var decision registry.RoutingDecision
	var excludeProviders []string
	for attempt := 0; attempt < 3; attempt++ {
		provider, decision = s.registry.ReserveProviderEx(model, pr, excludeProviders...)
		if provider == nil {
			break
		}

		// Settles FREE when served by the caller's own machine: exclusive
		// self-route always, or a prefer request whose selected provider is owned
		// (settlement refunds to zero). Skip the payout warning + custom-price
		// top-up then (the top-up could otherwise 429 the free owned route).
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

		// Custom pricing check — provider may charge more than the platform
		// rate. Skipped for free (owned) requests, which settle at zero cost.
		if s.billing != nil && !settlesFree {
			if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				excludeProviders = append(excludeProviders, provider.ID)
				if !errors.Is(err, store.ErrInsufficientBalance) {
					s.logger.Error("provider reservation failed (DB error)",
						"request_id", requestID,
						"provider_id", provider.ID,
						"error", err,
					)
				}
				continue
			}
		}

		// Provider passed all checks.
		break
	}
	if provider == nil {
		// Providers are available but all exceed the TTFT ceiling. Fail fast
		// with a retryable 429 rather than queueing for a provider that would
		// miss the OpenRouter SLA target.
		if decision.TTFTRejections > 0 {
			bestTTFT := time.Duration(decision.BestTTFTMs * float64(time.Millisecond))
			refundReservation()
			s.writeTTFTTooSlow(w, model, publicModel, bestTTFT, genericDeadline)
			return
		}

		// No online provider can physically fit this model — queueing/retrying
		// can't help, so fast-fail with a clear, non-retryable error instead of
		// blocking for 120s then 503-ing. Mirrors the streaming dispatch path.
		if decision.CandidateCount == 0 && decision.CapacityRejections == 0 && decision.ModelTooLargeRejections > 0 {
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q is too large for any currently available provider", publicModel),
				withCode("model_unavailable")))
			return
		}
		queuedReq := &registry.QueuedRequest{
			RequestID:  requestID,
			Model:      model,
			Pending:    pr,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		timing.QueuedAt = time.Now()
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:over_capacity"})
			s.recordRejection(rejectionForGenericWithDecision("queue", "queue_full", http.StatusTooManyRequests, retryAfter*1000, decision))
			if policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", publicModel),
					withCode("rate_limit_exceeded")))
			}
			return
		}
		s.recordWarmPoolQueueState(model)
		// Routing v2 W3: the model now has queued demand — proactively warm a cold
		// provider for it (TriggerModelSwaps) instead of waiting for the next
		// heartbeat, so the queued request drains onto it sooner.
		s.kickColdDispatch(model)
		s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:queued"})
		routeState := &dispatchState{
			s:                     s,
			r:                     r,
			model:                 model,
			publicModel:           publicModel,
			consumerKey:           consumerKey,
			consumerLocation:      consumerLocation,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			policy:                policy,
			cacheAffinityKey:      cacheAffinityKey,
			requestID:             requestID,
			attempt:               pr.Attempt,
			pr:                    pr,
		}
		routeState.recordRoutingDecisionFor(nil, pr, requestID, pr.Attempt, decision, "", "queued")
		provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				s.recordWarmPoolQueueState(model)
				s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "cancelled", "client_gone", 0))
				refundReservation()
				return
			}
			s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "timeout", "queue_timeout", http.StatusTooManyRequests))
			retryAfter := s.estimateRetryAfter(model)
			s.registry.RecordWarmPoolQueueTimeout(model, time.Since(queuedReq.EnqueuedAt))
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.recordRejection(rejectionForGenericWithDecision("queue", "queue_timeout", http.StatusTooManyRequests, retryAfter*1000, decision))
			if policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity (timed out waiting for a free slot) — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", publicModel),
					withCode("rate_limit_exceeded")))
			}
			return
		}
		s.recordWarmPoolQueueState(model)
		decision = queuedReq.Decision
	}
	timing.RoutedAt = time.Now()
	s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:selected"})
	s.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	s.ddHistogram("routing.cost_ms", decision.CostMs, []string{"model:" + model, "provider_id:" + provider.ID})
	if decision.EffectiveTPS > 0 {
		s.ddGauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})
	}
	routeState := &dispatchState{
		s:                     s,
		r:                     r,
		model:                 model,
		publicModel:           publicModel,
		consumerKey:           consumerKey,
		consumerLocation:      consumerLocation,
		estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens:    requestedMaxTokens,
		requiresVision:        requiresVision,
		hasTools:              hasTools,
		policy:                policy,
		cacheAffinityKey:      cacheAffinityKey,
		requestID:             requestID,
		attempt:               pr.Attempt,
		provider:              provider,
		pr:                    pr,
	}
	routeState.recordRoutingDecisionFor(provider, pr, requestID, pr.Attempt, decision, "", "")
	pendingCleanup := true
	cleanupPending := func() {
		if pendingCleanup {
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			pendingCleanup = false
		}
	}
	defer cleanupPending()
	// Settles FREE when served by the caller's own machine (exclusive self-route,
	// or a prefer request whose selected provider is owned — settlement refunds
	// to zero). Skip the payout warning + custom-price top-up then.
	settlesFreeDirect := policy.enabled
	if !settlesFreeDirect && policy.prefer {
		provider.Mu().Lock()
		settlesFreeDirect = policy.ownerAccountID != "" && provider.AccountID == policy.ownerAccountID
		provider.Mu().Unlock()
	}
	if s.billing != nil && !settlesFreeDirect && !providerHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}
	// Free (owned) requests settle at zero cost — no provider-price top-up.
	if s.billing != nil && !settlesFreeDirect {
		if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
			cleanupPending()
			refundExtra()
			refundReservation()
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.recordRejection(rejectionInfo{
					r:                     r,
					stage:                 "balance",
					reasonCode:            "insufficient_funds",
					httpStatus:            http.StatusPaymentRequired,
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
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this provider price — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("provider reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "provider_error", http.StatusServiceUnavailable))
				s.writeServiceUnavailable(w, model)
			}
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "insufficient_funds", http.StatusPaymentRequired))
			}
			return
		}
	}

	inferenceBody, _ := marshalForwardBody(parsed)

	// Re-check the cap on the FINAL body we'll seal (the input cap bounded the
	// read; this body was re-marshaled after mutation). A body over the cap seals
	// into a frame the provider rejects by tearing down its session — return a
	// clean 413 instead (see maxInferenceBodyBytes). Billing is already reserved
	// at this point, so refund before returning.
	if len(inferenceBody) > maxInferenceBodyBytes {
		cleanupPending()
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "payload_too_large", http.StatusRequestEntityTooLarge))
		s.recordRejection(rejectionInfo{
			r:                     r,
			stage:                 "validation",
			reasonCode:            "payload_too_large",
			httpStatus:            http.StatusRequestEntityTooLarge,
			keyID:                 keyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(consumerKeyFromContext(r.Context())),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                stream,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			requestBodyBytes:      len(inferenceBody),
			params:                rejectionSamplingParams(parsed),
		})
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error",
			fmt.Sprintf("request body exceeds the %d-byte limit", maxInferenceBodyBytes)))
		return
	}

	if provider.PublicKey == "" {
		cleanupPending()
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "encryption_missing", http.StatusServiceUnavailable))
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "encryption_error", http.StatusInternalServerError))
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "encryption_error", http.StatusInternalServerError))
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to generate session keys"))
		return
	}

	// Version-gated penalty strip for vision requests (Anthropic /v1/messages
	// carries image blocks); this handler seals separately from dispatchOneProvider.
	inferenceBody = bodyForProvider(inferenceBody, requiresVision, provider)
	encrypted, err := e2e.Encrypt(inferenceBody, providerPubKey, sessionKeys)
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "encryption_error", http.StatusInternalServerError))
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to encrypt request"))
		return
	}
	timing.EncryptedAt = time.Now()

	wireMsg := map[string]any{
		"type":       protocol.TypeInferenceRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	}

	pr.SessionPrivKey = &sessionKeys.PrivateKey
	data, _ := json.Marshal(wireMsg)
	timing.DispatchedAt = time.Now()
	if err := writeProviderInferenceRequest(r.Context(), provider, data); err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, dispatchFailedPendingRouteOutcome(pr, "provider_error", http.StatusBadGateway))
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "failed to send request to provider"))
		return
	}
	pendingCleanup = false

	s.logger.Info("inference request dispatched",
		"request_id", requestID,
		"model", model,
		"provider_id", provider.ID,
		"endpoint", endpoint,
		"stream", stream,
	)

	// Dynamic TTFT deadline — wait for the first chunk or accepted signal
	// before committing. This mirrors the chat completions path but without
	// speculative dispatch (single attempt). If the provider misses the
	// TTFT deadline, the request fails instead of streaming forever.
	ttftTimer := time.NewTimer(genericDeadline)
	var firstChunk string
	committed := false
	accepted := false

	select {
	case <-pr.AcceptedCh:
		ttftTimer.Stop()
		accepted = true
	case chunk, ok := <-pr.ChunkCh:
		ttftTimer.Stop()
		if ok {
			firstChunk = chunk
			pr.MarkFirstChunkArrived()
			committed = true
		} else {
			select {
			case errMsg := <-pr.ErrorCh:
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.sendProviderCancel(provider, requestID)
				refundExtra()
				refundReservation()
				s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
				s.updateInferenceRouteOutcomeForPending(pr, preCommitProviderErrorOutcome(pr, errMsg))
				statusCode := errMsg.StatusCode
				if statusCode == 0 {
					statusCode = http.StatusBadGateway
				}
				writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
				return
			default:
				committed = true
			}
		}
	case errMsg := <-pr.ErrorCh:
		ttftTimer.Stop()
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
		s.updateInferenceRouteOutcomeForPending(pr, preCommitProviderErrorOutcome(pr, errMsg))
		statusCode := errMsg.StatusCode
		if statusCode == 0 {
			statusCode = http.StatusBadGateway
		}
		writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
		return
	case <-ttftTimer.C:
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		s.ddIncr("inference.dispatches", []string{"status:timeout"})
		s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "timeout", "first_chunk_timeout", http.StatusGatewayTimeout))
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "provider did not respond within TTFT deadline"))
		return
	case <-r.Context().Done():
		ttftTimer.Stop()
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "cancelled", "client_gone", 0))
		return
	}

	// If provider accepted (model reload), wait for first chunk with extended deadline.
	if accepted && !committed {
		chunkTimer := time.NewTimer(inferenceTimeout)
		select {
		case chunk, ok := <-pr.ChunkCh:
			chunkTimer.Stop()
			if ok {
				firstChunk = chunk
				pr.MarkFirstChunkArrived()
				committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					provider.RemovePending(requestID)
					s.registry.SetProviderIdle(provider.ID)
					s.sendProviderCancel(provider, requestID)
					refundExtra()
					refundReservation()
					s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
					s.updateInferenceRouteOutcomeForPending(pr, preCommitProviderErrorOutcome(pr, errMsg))
					statusCode := errMsg.StatusCode
					if statusCode == 0 {
						statusCode = http.StatusBadGateway
					}
					writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
					return
				default:
					committed = true
				}
			}
		case errMsg := <-pr.ErrorCh:
			chunkTimer.Stop()
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			refundExtra()
			refundReservation()
			s.noteInferenceError(provider.ID, pr, errMsg.StatusCode)
			s.updateInferenceRouteOutcomeForPending(pr, preCommitProviderErrorOutcome(pr, errMsg))
			statusCode := errMsg.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusBadGateway
			}
			writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
			return
		case <-chunkTimer.C:
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			refundExtra()
			refundReservation()
			// Accepted-then-silent is a provider-at-fault 504 — feed the
			// breaker (single-attempt path: no retry here, but repeated
			// stalls must still accumulate into the routing cooldown).
			s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout)
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "timeout", "accepted_timeout", http.StatusGatewayTimeout))
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "provider accepted but timed out before first chunk"))
			return
		case <-r.Context().Done():
			chunkTimer.Stop()
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			refundExtra()
			refundReservation()
			s.updateInferenceRouteOutcomeForPending(pr, pendingRouteOutcome(pr, "cancelled", "client_gone", 0))
			return
		}
	}

	if !committed {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		s.updateInferenceRouteOutcomeForPending(pr, providerFailedPendingRouteOutcome(pr, "error", "provider_incomplete", http.StatusServiceUnavailable))
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_error", "failed to get first chunk from provider"))
		return
	}
	s.updateInferenceRouteOutcomeForPending(pr, committedRouteOutcome(pr))

	// Free the slot, stop the provider, and preserve billing on a mid-stream
	// disconnect (park-before-remove + post-terminal sweep; see the
	// chat-completions path for the full rationale).
	defer func() {
		if stale := provider.GetPending(requestID); stale != nil {
			s.holdForSettlement(stale)
		} else {
			refundPr := pr
			saferun.Go(s.logger, "api.postTerminalSweep", func() {
				s.refundReservedBalance(refundPr, "post_terminal_sweep:"+requestID)
			})
		}
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	var firstChunks []string
	if firstChunk != "" {
		firstChunks = []string{firstChunk}
	}
	if stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	}
}

// errorDetailOpt carries optional fields for OpenAI-compatible error responses.
type errorDetailOpt struct {
	param string // e.g. "model", "max_tokens"
	code  string // e.g. "model_not_found", "insufficient_quota"
}

// errorResponse builds a standard OpenAI-compatible error response body.
// By default, code is inferred from errType. Callers can override code or
// set param via withParam / withCode helpers.
func errorResponse(errType, message string, opts ...errorDetailOpt) map[string]any {
	detail := map[string]any{
		"type":    errType,
		"message": message,
		"code":    errType, // default: code mirrors type
	}
	for _, o := range opts {
		if o.param != "" {
			detail["param"] = o.param
		}
		if o.code != "" {
			detail["code"] = o.code
		}
	}
	return map[string]any{
		"error": detail,
	}
}

// withParam returns an option that sets the "param" field on an error response.
func withParam(p string) errorDetailOpt { return errorDetailOpt{param: p} }

// withCode returns an option that overrides the "code" field on an error response.
func withCode(c string) errorDetailOpt { return errorDetailOpt{code: c} }
