package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
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
	if err := provider.Conn.Write(ctx, websocket.MessageText, cancelData); err != nil {
		s.logger.Debug("failed to send cancel (provider may have disconnected)",
			"request_id", requestID, "error", err)
	}
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

// dispatchOneProvider encrypts and sends an inference request to a single
// provider. It returns the pending request and provider on success, or an
// error string on failure. The excludeProviders set is updated on failure.
// selfRoutePolicy and its resolvers live in self_route.go.

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
	// TTFT is above the threshold. P1 fix: only enforce it when the HARD gate is
	// on — soft mode (default) leaves MaxTTFTMs 0 so dispatch serves the best-
	// available provider instead of re-rejecting an over-threshold request the
	// preflight already chose to soft-serve (mirrors queueMaxTTFTMs).
	if !policy.enabled && !policy.prefer && s.ttftHardReject {
		pr.MaxTTFTMs = float64(ttftDeadline(estimatedPromptTokens).Milliseconds())
	}

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
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		refundExtra()
		cleanupPending()
		excludeProviders[provider.ID] = struct{}{}
		return nil, nil, decision, "failed to send request to provider", http.StatusBadGateway
	}
	pendingCleanup = false
	if pr.Timing != nil {
		pr.Timing.DispatchedAt = time.Now()
	}

	return provider, pr, decision, "", 0
}
