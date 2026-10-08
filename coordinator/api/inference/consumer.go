package inference

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/backoff"
	dispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	infermedia "github.com/eigeninference/d-inference/coordinator/internal/inference/media"
	providerwire "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	retry "github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	routeplan "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	// defaultFirstContentDeadlineBase preserves the ordinary coordinator and
	// unit-test budget. Production overrides it to 9s through validated startup
	// configuration; exact model overrides live in modelpolicy and every request
	// adds 1ms per estimated prompt token.
	defaultFirstContentDeadlineBase = 5 * time.Second

	// chunkBufferSize is the channel buffer size for SSE chunks flowing from
	// the provider to the consumer. A larger buffer prevents dropped chunks
	// when the consumer reads slowly.
	chunkBufferSize = dispatch.ChunkBufferSize

	// maxDispatchAttempts is a SAFETY CEILING on per-request provider failover,
	// not the normal stopping point. A request keeps failing over to fresh
	// healthy providers until one succeeds, OR candidates are exhausted (every
	// failed provider is excluded from re-selection, so Primary.Run returns
	// attempt.FailFast once no eligible provider remains), OR
	// the request's deadline/context fires (attempt.Loop checks it each
	// attempt). This ceiling only guards against a pathological retry path that
	// fails to exclude a provider (an unbounded hot loop); it is set well above
	// any realistic per-request fault count. Retries never re-queue — only the
	// first attempt may wait for capacity — so failover stays fast, walking the
	// immediately-available healthy providers rather than waiting on busy ones.
	maxDispatchAttempts = 64
)

// FirstContentDeadline returns this server's request-absolute first-content
// policy duration for a concrete model. Account enforcement is selected by
// requestFirstContentDeadline; this helper also supplies a hedge timing hint.
// The ordinary base is instance-owned so
// production-like E2E servers can use the production value without mutating
// concurrent unit tests. Exact-model overrides and per-token slopes are
// centralized in modelpolicy.
func (s *Owner) FirstContentDeadline(model string, estimatedPromptTokens int) time.Duration {
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
func (s *Owner) shedIfModelRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, policy selfRoutePolicy, publicModel, model string, stream bool, estimatedPromptTokens, requestedMaxTokens int, requiresVision, hasTools bool) bool {
	return s.NewModelShedder().Shed(w, r, parsed, dispatch.Scope{SelfRouteOnly: policy.enabled, PreferOwner: policy.prefer}, publicModel, model, stream, estimatedPromptTokens, requestedMaxTokens, requiresVision, hasTools)
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
func (s *Owner) writeGenericProviderError(w http.ResponseWriter, errMsg protocol.InferenceErrorMessage) {
	errMsg = failure.NormalizeInternalError(errMsg)
	if retry.TemplateRejectEnabled() && failure.IsJinjaTemplateErrorReason(errMsg.ErrorReason) {
		httpx.WriteJSON(w, http.StatusUnprocessableEntity, httpx.ErrorResponse("invalid_request_error", retry.TemplateRejectMessage, httpx.WithCode("model_capability")))
		return
	}
	if failure.NormalizeReason(errMsg.ErrorReason) == failure.ErrorReasonToolNoncompliance {
		httpx.WriteJSON(w, http.StatusUnprocessableEntity, httpx.ErrorResponse("invalid_request_error", failure.ClientSafeMessage(errMsg), httpx.WithCode("model_capability")))
		return
	}
	statusCode := errMsg.StatusCode
	if statusCode == 0 {
		statusCode = http.StatusBadGateway
	}
	httpx.WriteJSON(w, statusCode, httpx.ErrorResponse("provider_error", failure.ClientSafeMessage(errMsg)))
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
const errModelTooLarge = dispatch.ModelTooLarge

// errTTFTTooSlow is the dispatch error returned when providers are available
// but all of them exceed the per-request TTFT ceiling. Distinct from
// "no provider available" so the caller returns a retryable 429 instead of
// queueing for a provider that would miss the OpenRouter SLA target.
const errTTFTTooSlow = dispatch.TTFTTooSlow

// errRoutingScanSaturated is returned when no provider-selection scan slot
// (Server.routingScanSem) freed up within the request's remaining
// first-content budget: the coordinator itself is the bottleneck (the
// 2026-09-01 congestion collapse). No provider was scanned or contacted, so
// callers shed ONE capacity-shaped retryable 429 — never a 5xx, never more
// scans.
const errRoutingScanSaturated = dispatch.RoutingScanSaturated

// errClientGoneBeforeScan is returned when the caller's context fired while
// the dispatch goroutine was parked for a provider-selection scan slot. No
// provider was scanned or contacted; the dispatch loop takes its ordinary
// client-gone terminal (cancelled route outcome, refund, no response body) —
// never the routing_saturated 429 or a rejection-ledger row.
const errClientGoneBeforeScan = dispatch.ClientGoneBeforeScan

// resolveRequestedModel maps the consumer-requested model — which may be a
// public alias like "gemma-4-26b" — to the concrete build id used for routing,
// billing, and serving, returning the public name to echo back to the consumer.
// When the request used an alias it rewrites parsed["model"] and returns an
// updated rawBody so the provider receives the concrete build. Raw build ids
// pass through unchanged (publicModel == buildModel). ok=false means the alias
// currently has no usable build; the caller should surface a model_unavailable
// error.
func (s *Owner) resolveRequestedModel(
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
	rb, err := inreq.MarshalForwardBody(parsed)
	if err != nil {
		rb = rawBody
	}
	return buildID, requested, rb, true
}

// aliasFallbackMode selects the failure policy for maybeFallbackAlias.
type aliasFallbackMode = routeplan.AliasFallbackMode

const (
	// aliasFallbackCapacity routes to Previous whenever it has any free capacity.
	aliasFallbackCapacity = routeplan.FallbackCapacity
	// aliasFallbackTTFT additionally rejects Previous when its best TTFT estimate
	// would miss the per-request ceiling (ttftThreshold).
	aliasFallbackTTFT = routeplan.FallbackTTFT
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
func (s *Owner) maybeFallbackAlias(parsed map[string]any, mode aliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string, firstContentQuery ...func(string) *registry.PendingRequest) (string, int, int, int, time.Duration, bool, bool) {
	return s.NewAliasPlanner().Fallback(parsed, mode, publicModel, currentModel, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, traits, requiresVision, allowedProviderSerials, firstContentQuery...)
}

func ttftTooSlow(bestTTFT time.Duration, hasTTFT bool, threshold time.Duration) bool {
	return routeplan.TTFTTooSlow(bestTTFT, hasTTFT, threshold)
}

// hardTTFTGateApplies reports whether the scheduler's token-prefill estimate is
// authoritative enough to reject this request before dispatch. Media requests
// run CPU decode plus a separate vision tower before text prefill; neither cost
// exists in estimatedTTFTFromSnapshot, so treating that partial estimate as a
// hard ceiling rejects healthy video/image requests on a number that cannot
// predict their TTFT. They still use the best-available provider and remain
// bounded by the same request-absolute first-content deadline.
func (s *Owner) hardTTFTGateApplies(requiresVision bool) bool {
	return s.ttftHardReject && !requiresVision
}

func fasterTTFTEstimate(primaryModel string, primary time.Duration, alternateModel string, alternate time.Duration, alternateOK bool) (string, time.Duration) {
	if alternateOK && alternate < primary {
		return alternateModel, alternate
	}
	return primaryModel, primary
}

func (s *Owner) estimateTTFTRetryAfter(model string, bestTTFT, threshold time.Duration) int {
	return s.backoff.TTFTRetryAfter(model, bestTTFT, threshold)
}

func (s *Owner) writeTTFTTooSlow(w http.ResponseWriter, model, publicModel string, bestTTFT, threshold time.Duration) {
	s.backoff.TTFTTooSlow(w, model, publicModel, bestTTFT, threshold)
}

// ttftTooSlowMessage is the single wording for a fleet-wide TTFT rejection.
func ttftTooSlowMessage(publicModel string, bestTTFT, threshold time.Duration, retryAfter int) string {
	return backoff.TTFTMessage(publicModel, bestTTFT, threshold, retryAfter)
}

func (s *Owner) triggerWarmPool() {
	if s == nil || s.registry == nil {
		return
	}
	s.registry.RequestWarmPoolTrigger()
}

func (s *Owner) recordWarmPoolQueueState(model string) {
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

type routeDecisionRecorder = dispatch.RouteRecorder

func providerBodySizeError(
	rawBody []byte,
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
	return providerwire.CacheAttemptSizeError(rawBody, legacyKey)
}

// defaultMaxOutputTokens is the ceiling injected into requests that don't set
// max_tokens. It bounds the worst-case cost of a single inference so the
// pre-flight balance reservation covers the entire generation; without this
// cap a consumer could stream output exceeding their reservation and the
// post-inference charge would fail silently (see GitHub issue #33). Consumers
// who need longer generations must set max_tokens explicitly and carry the
// balance to cover it.
const defaultMaxOutputTokens = 8192

// reservationCost is the pre-flight worst-case cost for a text inference
// request. It mirrors the platform-price branch of handleComplete's billing
// so the reservation covers any platform-level custom price for the model;
// without this, a platform override above the built-in default would leave
// the reservation short and the post-inference clamp would silently
// undercharge. Provider-specific custom prices are not known until dispatch
// commits to a provider, so a provider that sets a custom price above the
// platform rate accepts revenue capped at the reservation.
//
// Prefix-cache hits are unknown until the provider reports them and only ever
// lower the bill, so the reservation prices every prompt token at the full
// input rate; settlement refunds the cache-read discount.
func (s *Owner) reservationCost(model string, promptTokens, maxTokens int) int64 {
	return s.reservations.Cost(model, promptTokens, maxTokens)
}

func (s *Owner) refundReservedBalance(pr *registry.PendingRequest, reference string) bool {
	return s.reservations.Refund(pr, reference)
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
func (s *Owner) estimateRetryAfter(model string) int {
	return s.backoff.Estimate(model)
}

// writeServiceUnavailable writes a retryable 503 with a Retry-After header so
// clients (and OpenRouter) can schedule the retry instead of blind backoff.
func (s *Owner) writeServiceUnavailable(w http.ResponseWriter, model string) {
	s.backoff.Unavailable(w, model)
}

func providerPricingKeys(provider *registry.Provider) string {
	if provider == nil {
		return ""
	}
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	return provider.AccountID
}

// isServiceConsumer reports whether the account is a service/wholesale account
// (e.g. OpenRouter). Such accounts are billed at the advertised platform price,
// so the provider-price reservation top-up and provider custom pricing are
// skipped for them. A failed lookup falls back to false (normal consumer).
func (s *Owner) isServiceConsumer(accountID string) bool {
	if accountID == "" {
		return false
	}
	if u, err := s.store.GetUserByAccountID(accountID); err == nil && u != nil {
		return u.Role == store.RoleService
	}
	return false
}

func (s *Owner) reserveAdditionalForProvider(pr *registry.PendingRequest, provider *registry.Provider) (int64, error) {
	return s.reservations.ReserveAdditionalForProvider(pr, provider)
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
func (s *Owner) HandleChatCompletions(w http.ResponseWriter, r *http.Request) {
	r = withModelTokenRequest(r)
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.observation.NewRequestProfile(r, "", "", false)

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
	body := &prelude.Body
	originalRawBody := prelude.OriginalRawBody
	parsed := prelude.Parsed
	model := prelude.Model
	runtimeDefaults := inreq.NewModelRuntimeDefaults(parsed)
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
			keyID:           access.KeyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "messages or input is required"))
		return
	}

	// Multiple choices per request are not supported — fail loudly instead of
	// silently returning a single choice the consumer didn't ask for.
	if copies, ok := inreq.IntFromRequestValue(parsed["n"]); ok && copies > 1 {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "validation",
			reasonCode:      "bad_param",
			httpStatus:      http.StatusBadRequest,
			keyID:           access.KeyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:  model,
			n:               copies,
			params:          rejectionSamplingParams(parsed),
		})
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"n > 1 is not supported", httpx.WithParam("n")))
		return
	}

	var allowedProviderSerials []string
	if inreq.StripProviderRoutingFields(parsed) {
		body.MarkDirty()
	}
	if inreq.ApplyMetadataDetailsRequest(r, parsed) {
		body.MarkDirty()
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
	var validatedPolicy inreq.ValidatedToolConstraintPolicy
	var validationErr error
	if isResponsesAPI {
		loweredConstraintBody, err := promptcontract.LowerResponsesInferenceBody(originalRawBody)
		if err != nil {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse(
				"invalid_request_error", err.Error()))
			return
		}
		validatedPolicy, validationErr = inreq.ValidateToolConstraintPolicy(loweredConstraintBody)
	} else {
		validatedPolicy, validationErr = inreq.ValidateParsedToolConstraintPolicy(
			inreq.ConstraintView(parsed, prelude.OriginalTools))
	}
	if validationErr != nil {
		s.recordToolConstraintMetric(validatedPolicy.Mode, "compile_rejection")
		inreq.WriteToolConstraintValidationError(w, validationErr)
		return
	}
	// Derive request-shape traits before alias resolution. During a
	// mixed-version rollout Desired may have ordinary providers while Previous
	// has the only provider capable of enforcing this exact tool policy. One
	// walk of the message tree yields the media count, the tools flag, and the
	// routing/billing token estimates (consumed below, after the rewrites). It
	// runs after constraint validation so a rejected tool policy on a large
	// body never pays the walk.
	shape := inreq.IntrospectRequest(parsed)
	requiresVision := shape.RequiresVision()
	hasTools := shape.HasTools
	validatedMode := validatedPolicy.Mode
	toolChoiceName := validatedPolicy.Name
	parallelToolCalls := validatedPolicy.Parallel
	s.recordToolConstraintMetric(validatedMode, "requested")
	requiresToolConstraint := validatedMode.RequiresInferenceConstraint()
	requiresNativeMediaTools := requiresVision && (requiresToolConstraint || inreq.RequestHasMediaToolResults(parsed))
	aliasTraits := registry.RequestTraits{
		HasTools:                 hasTools,
		RequiresToolConstraint:   requiresToolConstraint,
		RequiresNativeMediaTools: requiresNativeMediaTools,
		ToolChoiceMode:           string(validatedMode),
		ToolChoiceName:           toolChoiceName,
		ParallelToolCalls:        parallelToolCalls,
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
			keyID:           access.KeyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), httpx.WithParam("model")))
		return
	}
	model = buildModel
	if modelRewritten {
		body.MarkDirty()
	}
	user := auth.UserFromContext(r.Context())
	serviceChatConsumer := r.URL.Path == "/v1/chat/completions" &&
		user != nil && user.Role == store.RoleService
	if inreq.ApplyResolvedModelReasoningPolicy(parsed, model, serviceChatConsumer, reasoningProvided) {
		body.MarkDirty()
	}

	// The serving lowerer has already validated Responses media without dropping
	// content. Keep the ordinary vision/provider capability gates on both APIs.
	if requiresNativeMediaTools && s.nativeMediaToolsFailFast(w, model, publicModel, policy, allowedProviderSerials) {
		return
	}
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		requiresToolConstraint, string(validatedMode),
		policy, allowedProviderSerials) {
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
		observation.ProfileDBCall(rp, registryReadStart)
		resolvedRuntimeParameters = rec.RuntimeParameters
		if runtimeDefaults.Apply(parsed, rec.RuntimeParameters) {
			body.MarkDirty()
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
	if err := inreq.ValidateResolvedToolConstraintParser(
		parsed, validatedMode, model, s.registry.ModelType(model),
		resolvedRuntimeParameters,
	); err != nil {
		s.recordToolConstraintMetric(validatedMode, "compile_rejection")
		inreq.WriteToolConstraintValidationError(w, err)
		return
	}

	// Bound the generation so the pre-flight reservation covers it. If the
	// consumer didn't set max_tokens, inject the model's max_output_length
	// (or defaultMaxOutputTokens as fallback). Without this bound the
	// provider could return more tokens than we reserved for, and the
	// silent post-inference charge failure would hand the consumer free
	// inference (GitHub issue #33).
	if providerwire.EnsureMaxTokensBound(parsed, isResponsesAPI, maxOutputBound) {
		body.MarkDirty()
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := shape.RoutingPromptTokens(parsed)
	estimatedPromptTokens = s.mediaPromptTokens(r.Context(), publicModel, model, parsed, estimatedPromptTokens)
	billingPromptTokens := shape.BillingPromptTokens(parsed)
	requestedMaxTokens := inreq.EstimateRequestedMaxTokens(parsed)
	deadline, deadlineErr := s.requestFirstContentDeadline(r, publicModel, model, estimatedPromptTokens)
	if deadlineErr != nil {
		s.writeServiceUnavailable(w, model)
		return
	}
	timing.ParsedAt = time.Now()
	rp.Mark(registry.StampReqParsed)
	if s.shedIfModelRejected(w, r, parsed, policy, publicModel, model, stream, estimatedPromptTokens, requestedMaxTokens, requiresVision, hasTools) {
		return
	}

	// Single serialization point: every rewrite above (stop, stripped fields,
	// alias, reasoning policy, runtime defaults, max_tokens) landed in parsed;
	// serialize once here — or hand the caller's exact bytes through when
	// nothing changed.
	rawBody, err := body.Current()
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse(
			"server_error", "failed to prepare inference request"))
		return
	}
	providerBody := rawBody
	if isResponsesAPI {
		loweredProviderBody, err := promptcontract.LowerResponsesInferenceBody(rawBody)
		if err != nil {
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "validation",
				reasonCode:            "bad_param",
				httpStatus:            http.StatusBadRequest,
				keyID:                 access.KeyIDFromContext(r.Context()),
				consumerKeyHash:       store.HashKey(access.ConsumerKeyFromContext(r.Context())),
				requestedModel:        publicModel,
				resolvedModel:         model,
				stream:                stream,
				estimatedPromptTokens: estimatedPromptTokens,
				requestedMaxTokens:    requestedMaxTokens,
				requiresVision:        requiresVision,
				hasTools:              hasTools,
				params:                rejectionSamplingParams(parsed),
			})
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
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
	bodies := providerwire.NewMemo(func(candidateModel string) ([]byte, error) {
		return s.candidateProviderBody(parsed, runtimeDefaults, candidateModel,
			serviceChatConsumer, reasoningProvided, isResponsesAPI)
	}, hasTools)
	if body.Serialized {
		bodies.Seed(model, providerBody)
	}
	routingTraitsForModel := func(candidateModel string) registry.RequestTraits {
		traits, ok := bodies.Traits(candidateModel)
		if !ok {
			traits = registry.RequestTraits{HasTools: hasTools}
		}
		traits.RequiresToolConstraint = requiresToolConstraint
		traits.RequiresNativeMediaTools = requiresNativeMediaTools
		traits.ToolChoiceMode = string(validatedMode)
		traits.ToolChoiceName = toolChoiceName
		traits.ParallelToolCalls = parallelToolCalls
		return traits
	}
	providerBodyErrorForModel := bodies.SizeError
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
		if s.releaseModelTokenRequest(r) {
			return
		}
		if reservedMicroUSD > 0 {
			s.releaseInitialReservation(access.ConsumerKeyFromContext(r.Context()), model, reservedMicroUSD, serviceReservation)
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
			keyID:                 access.KeyIDFromContext(r.Context()),
			consumerKeyHash:       store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:        publicModel,
			resolvedModel:         model,
			stream:                stream,
			estimatedPromptTokens: estimatedPromptTokens,
			requestedMaxTokens:    requestedMaxTokens,
			requiresVision:        requiresVision,
			hasTools:              hasTools,
			params:                rejectionSamplingParams(parsed),
		})
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), httpx.WithParam("model")))
		return
	}

	// Resolve remote http(s) image_url/video_url links into inline base64 data:
	// URIs (phase 2 — see media_resolve.go) — AFTER token admission, the balance
	// reservation, and the catalog check, so network I/O is gated behind the
	// cost gates: an authenticated but unfunded/over-quota request (or one for a
	// nonexistent model) can never drive coordinator-side fetches. The token &
	// routing estimates above can inspect already-inline metadata; unresolved
	// URLs keep legacy per-part estimates until the post-fetch recount below.
	// The billing reservation is refunded on
	// any failure, and topped up below on success — it was taken while the media
	// was still a ~100-byte URL. parsed is mutated in place, so every view
	// derived from the pre-inline body is refreshed via refreshForwardBody.
	var mediaInlined bool
	rawBody, mediaInlined, ok = s.resolveRemoteMedia(w, r, rawBody, parsed, timing, infermedia.ResolveMeta{
		Model:                   model,
		PublicModel:             publicModel,
		Stream:                  stream,
		EstimatedPromptTokens:   estimatedPromptTokens,
		FirstContentDeadline:    deadline,
		FirstContentDeadlineSet: true,
		RequestedMaxTokens:      requestedMaxTokens,
		HasTools:                hasTools,
		RequiresVision:          requiresVision,
		SelfRoute:               policy.enabled,
		OwnerAccountID:          policy.ownerAccountID,
		Traits:                  routingTraits,
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
		body.Replace(forwardBytes)
		bodies.Reset()
		if !isResponsesAPI {
			providerBody = rawBody
			bodies.Seed(forModel, providerBody)
			routingTraits = routingTraitsForModel(forModel)
			return true
		}
		var err error
		providerBody, err = promptcontract.LowerResponsesInferenceBody(rawBody)
		if err != nil {
			refundReservation()
			s.recordRejection(rejectionInfo{
				r:                     r,
				stage:                 "validation",
				reasonCode:            "bad_param",
				httpStatus:            http.StatusBadRequest,
				keyID:                 access.KeyIDFromContext(r.Context()),
				consumerKeyHash:       store.HashKey(access.ConsumerKeyFromContext(r.Context())),
				requestedModel:        publicModel,
				resolvedModel:         forModel,
				stream:                stream,
				estimatedPromptTokens: estimatedPromptTokens,
				requestedMaxTokens:    requestedMaxTokens,
				requiresVision:        requiresVision,
				hasTools:              hasTools,
				params:                rejectionSamplingParams(parsed),
			})
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", err.Error()))
			return false
		}
		bodies.Seed(forModel, providerBody)
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
		// URLs were cost-gated before fetching. Recount the now-inline media
		// from the original flat estimate, never adding the same image twice.
		// A larger input charge must pass both token limiters before dispatch.
		estimatedPromptTokens, deadline, ok = s.reconcileFetchedMedia(w, r, publicModel, model,
			parsed, shape.RoutingPromptTokens(parsed), estimatedPromptTokens, deadline)
		if !ok {
			refundReservation()
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
			billingPromptTokens:   inreq.EstimateBillingPromptTokens(parsed),
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
	// capacity+TTFT gate — see Admission.Run). On the chat path an alias
	// fallback must refresh the threaded rawBody; thread that as the
	// onModelFallback callback. resolvedModel uses the new build to match the
	// pre-extraction behavior.
	onModelFallback := func(newModel string) bool {
		var runtimeParameters map[string]any
		if rec, err := s.store.GetModelRegistryRecord(newModel); err == nil {
			runtimeParameters = rec.RuntimeParameters
			runtimeDefaults.Apply(parsed, runtimeParameters)
		} else {
			runtimeDefaults.Apply(parsed, nil)
		}
		if err := inreq.ValidateResolvedToolConstraintParser(
			parsed, validatedMode, newModel, s.registry.ModelType(newModel),
			runtimeParameters,
		); err != nil {
			s.recordToolConstraintMetric(validatedMode, "compile_rejection")
			inreq.WriteToolConstraintValidationError(w, err)
			refundReservation()
			return false
		}
		inreq.ApplyResolvedModelReasoningPolicy(parsed, newModel, serviceChatConsumer, reasoningProvided)
		// maybeFallbackAlias rewrote parsed["model"]; the defaults and reasoning
		// policy above may have moved more. One serialization covers all of it.
		body.MarkDirty()
		forwardBytes, err := body.Current()
		if err != nil {
			refundReservation()
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse(
				"server_error", "failed to prepare inference request"))
			return false
		}
		return refreshForwardBody(forwardBytes, newModel)
	}
	cachePlans := routeplan.New(
		bodies.Body,
		func(candidateModel string, candidateBody []byte, hasMedia bool) promptwork.Result {
			ctx, cancel := promptwork.PlanningContext(r.Context(), firstcontent.TimingReceivedAt(timing), deadline)
			defer cancel()
			return s.planPromptRoute(ctx, access.ConsumerKeyFromContext(r.Context()), candidateModel, candidateBody, hasMedia, hasTools, estimatedPromptTokens)
		},
		requiresVision, parsed)
	r = r.WithContext(cachePlans.WithContext(r.Context()))
	preflightStart := time.Now()
	admission := s.NewAdmission().Run(w, r, parsed, AdmissionRequest{
		Model:                     model,
		PublicModel:               publicModel,
		Stream:                    stream,
		EstimatedPromptTokens:     estimatedPromptTokens,
		RequestedMaxTokens:        requestedMaxTokens,
		RequiresVision:            requiresVision,
		HasTools:                  hasTools,
		Traits:                    &routingTraits,
		TraitsForModel:            routingTraitsForModel,
		ProviderBodyErrorForModel: providerBodyErrorForModel,
		ModelMaxContext:           modelMaxContext,
		AllowedProviderSerials:    allowedProviderSerials,
		Deadline:                  deadline,
		ReceivedAt:                firstcontent.TimingReceivedAt(timing),
		CachePlanForModel:         cachePlans.ForModel,
		PromptWorkForModel:        cachePlans.WorkForModel,
		Policy:                    access.SelfRoutePolicy{Enabled: policy.enabled, Prefer: policy.prefer, OwnerAccountID: policy.ownerAccountID},
		RefundReservation:         refundReservation,
		OnModelFallback:           onModelFallback,
	})
	model = admission.Model
	if rp != nil {
		rp.PreflightUS = time.Since(preflightStart).Microseconds()
		rp.Mark(registry.StampReqPreflightDone)
		if admission.Handled {
			rp.PreflightOutcome = "handled"
		} else {
			rp.PreflightOutcome = "passed"
		}
	}
	if admission.Handled {
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
	consumerKey := access.ConsumerKeyFromContext(r.Context())
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
	observation.ProfileDBCall(rp, registryReadStart2)
	cachePlan := cachePlans.ForBody(model, providerBody)
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

	session := s.NewDispatchSession(DispatchRequest{
		Writer: w, Request: r, Model: model, PublicModel: publicModel, Body: providerBody,
		ConsumerKey: consumerKey, ConsumerLocation: consumerLocation,
		ReservedMicroUSD: reservedMicroUSD, TokenAdmission: tokenAdmission, ServiceReservation: serviceReservation,
		EstimatedPromptTokens: estimatedPromptTokens, RequestedMaxTokens: requestedMaxTokens,
		RequiresVision: requiresVision, VisionImageCount: shape.MediaParts,
		Traits: registry.RequestTraits{
			HasTools: hasTools, RequiresToolConstraint: requiresToolConstraint,
			ToolChoiceMode: string(validatedMode), ToolChoiceName: toolChoiceName, ParallelToolCalls: parallelToolCalls,
		},
		IsResponsesAPI: isResponsesAPI, Stream: stream, MetadataDetails: inreq.MetadataDetailsFromRequest(r),
		Scope:                  dispatch.Scope{SelfRouteOnly: policy.enabled, PreferOwner: policy.prefer, OwnerAccountID: policy.ownerAccountID},
		AllowedProviderSerials: allowedProviderSerials, CachePlan: cachePlan, Timing: timing, Profile: rp,
		Deadline: deadline, SpeculativeAt: s.firstContentHedgeDelay(model, estimatedPromptTokens, deadline),
		ModelMaxContext: modelMaxContext, RefundReservation: refundReservation,
	})
	session.Run(r.Context())
}

// microToUSD converts micro-USD to a USD float.
func microToUSD(micro int64) float64 { return float64(micro) / 1_000_000 }

// handleCompletions handles POST /v1/completions.
// Proxies OpenAI-compatible text completions to the selected provider over the
// E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Owner) HandleCompletions(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/completions")
}

// handleAnthropicMessages handles POST /v1/messages.
// Proxies the Anthropic-compatible messages API to the selected provider over
// the E2E-encrypted WebSocket relay (MLX-Swift in-process backend).
func (s *Owner) HandleAnthropicMessages(w http.ResponseWriter, r *http.Request) {
	s.handleGenericInference(w, r, "/v1/messages")
}

// handleGenericInference is the shared dispatch for completions and Anthropic endpoints.
// It reads the endpoint-native body, preserves it for accounting, lowers the
// final provider body to OpenAI chat format, and reuses the same E2E encryption
// and provider routing as chat completions.
func (s *Owner) handleGenericInference(w http.ResponseWriter, r *http.Request, endpoint string) {
	r = withModelTokenRequest(r)
	timing := &registry.RequestTiming{ReceivedAt: time.Now()}
	rp := s.observation.NewRequestProfile(r, "", "", false)

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
	rawBody := prelude.OriginalRawBody
	originalRawBody := prelude.OriginalRawBody
	parsed := prelude.Parsed
	model := prelude.Model
	runtimeDefaults := inreq.NewModelRuntimeDefaults(parsed)
	endpointKind := promptcontract.EndpointCompletions
	if endpoint == "/v1/messages" {
		endpointKind = promptcontract.EndpointMessages
	}

	var allowedProviderSerials []string
	inreq.StripProviderRoutingFields(parsed)
	inreq.ApplyMetadataDetailsRequest(r, parsed)

	// "Use my own machine, for free" opt-in (see handleChatCompletions).
	policy := s.resolveSelfRoutePolicy(r)

	// Constraint validation needs the lowered chat shape. Endpoint-native
	// shapes the contract lowering cannot express — multi-prompt completions,
	// media-bearing messages — have always been forwarded verbatim (see the
	// inferenceBody fallback below), so a lowering failure is only terminal
	// for requests that actually carry tool policy to validate; tool-less
	// unsupported shapes keep the pre-existing native-forward behavior with
	// the neutral auto defaults.
	validatedPolicy := inreq.ValidatedToolConstraintPolicy{
		Mode: inreq.ToolChoiceAuto, Parallel: true,
	}
	constraintBody, constraintLowerErr := promptcontract.LowerProviderBody(
		endpointKind, originalRawBody)
	if constraintLowerErr == nil {
		var validationErr error
		validatedPolicy, validationErr = inreq.ValidateToolConstraintPolicy(constraintBody)
		if validationErr != nil {
			s.recordToolConstraintMetric(validatedPolicy.Mode, "compile_rejection")
			inreq.WriteToolConstraintValidationError(w, validationErr)
			return
		}
	} else if _, hasToolChoice := parsed["tool_choice"]; hasToolChoice || inreq.RequestHasTools(parsed) {
		s.recordToolConstraintMetric(validatedPolicy.Mode, "compile_rejection")
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse(
			"invalid_request_error", constraintLowerErr.Error()))
		return
	}
	validatedMode := validatedPolicy.Mode
	toolChoiceName := validatedPolicy.Name
	parallelToolCalls := validatedPolicy.Parallel
	s.recordToolConstraintMetric(validatedMode, "requested")
	requiresToolConstraint := validatedMode.RequiresInferenceConstraint()
	requiresVision := inreq.DetectMediaRequirement(parsed)
	hasTools := inreq.RequestHasTools(parsed)
	requiresNativeMediaTools := requiresVision && (requiresToolConstraint || inreq.RequestHasMediaToolResults(parsed))
	aliasTraits := registry.RequestTraits{
		HasTools:                 hasTools,
		RequiresToolConstraint:   requiresToolConstraint,
		RequiresNativeMediaTools: requiresNativeMediaTools,
		ToolChoiceMode:           string(validatedMode),
		ToolChoiceName:           toolChoiceName,
		ParallelToolCalls:        parallelToolCalls,
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
			keyID:           access.KeyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:  model,
			params:          rejectionSamplingParams(parsed),
		})
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("model %q has no available build right now", model), httpx.WithParam("model")))
		return
	}
	model = buildModel

	if !policy.enabled && !s.registry.IsModelInCatalog(model) {
		s.recordRejection(rejectionInfo{
			r:               r,
			stage:           "model_resolution",
			reasonCode:      "model_not_found",
			httpStatus:      http.StatusNotFound,
			keyID:           access.KeyIDFromContext(r.Context()),
			consumerKeyHash: store.HashKey(access.ConsumerKeyFromContext(r.Context())),
			requestedModel:  publicModel,
			resolvedModel:   model,
			params:          rejectionSamplingParams(parsed),
		})
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", publicModel), httpx.WithParam("model")))
		return
	}
	// Shared media/tools fail-fast (see visionToolsFailFast).
	if requiresNativeMediaTools && s.nativeMediaToolsFailFast(w, model, publicModel, policy, allowedProviderSerials) {
		return
	}
	if s.visionToolsFailFast(w, model, publicModel, requiresVision, hasTools,
		requiresToolConstraint, string(validatedMode),
		policy, allowedProviderSerials) {
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
		runtimeDefaults.Apply(parsed, rec.RuntimeParameters)
		if rec.MaxOutputLength > 0 {
			genericMaxOutput = rec.MaxOutputLength
		}
		modelMaxContext = rec.MaxContextLength
	}
	providerwire.EnsureMaxTokensBound(parsed, false, genericMaxOutput)

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := inreq.EstimatePromptTokens(parsed)
	estimatedPromptTokens = s.mediaPromptTokens(r.Context(), publicModel, model, parsed, estimatedPromptTokens)
	billingPromptTokens := inreq.EstimateBillingPromptTokens(parsed)
	requestedMaxTokens := inreq.EstimateRequestedMaxTokens(parsed)
	genericDeadline, deadlineErr := s.requestFirstContentDeadline(r, publicModel, model, estimatedPromptTokens)
	if deadlineErr != nil {
		s.writeServiceUnavailable(w, model)
		return
	}
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
	consumerKey := access.ConsumerKeyFromContext(r.Context())
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
		if s.releaseModelTokenRequest(r) {
			return
		}
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
			candidateDefaults.Apply(candidateParsed, rec.RuntimeParameters)
		} else {
			candidateDefaults.Apply(candidateParsed, nil)
		}
		endpointBody, _ := inreq.MarshalForwardBody(candidateParsed)
		inferenceBody, loweringErr := promptcontract.LowerProviderBody(
			endpointKind, endpointBody)
		if loweringErr != nil {
			inferenceBody = endpointBody
		}
		return endpointBody, inferenceBody, loweringErr
	}
	routingTraitsForModel := func(candidateModel string) registry.RequestTraits {
		_, candidateBody, _ := lowerGenericBodyForModel(candidateModel)
		traits, _ := providerwire.RoutingTraits(
			hasTools, candidateBody)
		traits.RequiresToolConstraint = requiresToolConstraint
		traits.RequiresNativeMediaTools = requiresNativeMediaTools
		traits.ToolChoiceMode = string(validatedMode)
		traits.ToolChoiceName = toolChoiceName
		traits.ParallelToolCalls = parallelToolCalls
		return traits
	}
	providerBodyErrorForModel := func(candidateModel string) error {
		_, candidateBody, _ := lowerGenericBodyForModel(candidateModel)
		_, sizeErr := providerwire.RoutingTraits(
			hasTools, candidateBody)
		return sizeErr
	}
	var endpointBody, inferenceBody []byte
	var loweringErr error
	routingTraits := routingTraitsForModel(model)
	refreshGenericBody := func(newModel string) bool {
		var runtimeParameters map[string]any
		if rec, err := s.store.GetModelRegistryRecord(newModel); err == nil {
			runtimeParameters = rec.RuntimeParameters
			runtimeDefaults.Apply(parsed, runtimeParameters)
		} else {
			runtimeDefaults.Apply(parsed, nil)
		}
		if err := inreq.ValidateResolvedToolConstraintParser(
			parsed, validatedMode, newModel, s.registry.ModelType(newModel),
			runtimeParameters,
		); err != nil {
			s.recordToolConstraintMetric(validatedMode, "compile_rejection")
			inreq.WriteToolConstraintValidationError(w, err)
			refundReservation()
			return false
		}
		endpointBody, inferenceBody, loweringErr = lowerGenericBodyForModel(newModel)
		routingTraits, _ = providerwire.RoutingTraits(
			hasTools, inferenceBody)
		routingTraits.RequiresToolConstraint = requiresToolConstraint
		routingTraits.RequiresNativeMediaTools = requiresNativeMediaTools
		routingTraits.ToolChoiceMode = string(validatedMode)
		routingTraits.ToolChoiceName = toolChoiceName
		routingTraits.ParallelToolCalls = parallelToolCalls
		return true
	}
	if !refreshGenericBody(model) {
		return
	}

	// Shared routing/capacity admission preflight (self-route / prefer / public
	// capacity+TTFT gate — see Admission.Run).
	cachePlans := routeplan.New(
		func(candidateModel string) ([]byte, error) {
			_, candidateBody, err := lowerGenericBodyForModel(candidateModel)
			return candidateBody, err
		},
		func(candidateModel string, candidateBody []byte, hasMedia bool) promptwork.Result {
			ctx, cancel := promptwork.PlanningContext(r.Context(), firstcontent.TimingReceivedAt(timing), genericDeadline)
			defer cancel()
			return s.planPromptRoute(ctx, consumerKey, candidateModel, candidateBody, hasMedia, hasTools, estimatedPromptTokens)
		},
		requiresVision, parsed)
	r = r.WithContext(cachePlans.WithContext(r.Context()))
	preflightStart := time.Now()
	admission := s.NewAdmission().Run(w, r, parsed, AdmissionRequest{
		Model:                     model,
		PublicModel:               publicModel,
		Stream:                    stream,
		EstimatedPromptTokens:     estimatedPromptTokens,
		RequestedMaxTokens:        requestedMaxTokens,
		RequiresVision:            requiresVision,
		HasTools:                  hasTools,
		Traits:                    &routingTraits,
		TraitsForModel:            routingTraitsForModel,
		ProviderBodyErrorForModel: providerBodyErrorForModel,
		ModelMaxContext:           modelMaxContext,
		AllowedProviderSerials:    allowedProviderSerials,
		Deadline:                  genericDeadline,
		ReceivedAt:                firstcontent.TimingReceivedAt(timing),
		CachePlanForModel:         cachePlans.ForModel,
		PromptWorkForModel:        cachePlans.WorkForModel,
		Policy:                    access.SelfRoutePolicy{Enabled: policy.enabled, Prefer: policy.prefer, OwnerAccountID: policy.ownerAccountID},
		RefundReservation:         refundReservation,
		OnModelFallback:           refreshGenericBody,
	})
	model = admission.Model
	if rp != nil {
		rp.PreflightUS = time.Since(preflightStart).Microseconds()
		rp.Mark(registry.StampReqPreflightDone)
		if admission.Handled {
			rp.PreflightOutcome = "handled"
		} else {
			rp.PreflightOutcome = "passed"
		}
	}
	if admission.Handled {
		return
	}
	// Response framing is determined by the caller-facing endpoint, never by
	// whether its request shape could be lowered for cache participation.
	consumerEndpoint, requestedStopSequences := inreq.GenericResponseMetadata(endpoint, parsed)
	var cachePlan registry.CachePlan
	if loweringErr == nil {
		cachePlan = cachePlans.ForBody(model, inferenceBody)
	} else {
		// Endpoint lowering is a cache-routing eligibility boundary, not a new
		// inference rejection. Preserve the existing generic endpoint behavior
		// for unsupported shapes while declining cache participation.
		inferenceBody = endpointBody
		cachePlanner := s.NewCachePlanner()
		cachePlanner.EmitDecision(cachePlanner.ModelLabel(model), routeplan.CachePlanningLoweringUnsupported, 0)
	}

	// Generic endpoints use the same dispatch state machine as chat. This keeps
	// queue deadlines, speculative failover, pre-content boilerplate handling,
	// typed deadline refusals, and terminal 429 semantics identical.
	genericRegistryReadStart := time.Now()
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		modelMaxContext = rec.MaxContextLength
	}
	observation.ProfileDBCall(rp, genericRegistryReadStart)
	rp.Mark(registry.StampReqPlanDone)
	if rp != nil {
		rp.Model, rp.PublicModel, rp.Stream = model, publicModel, stream
		rp.FirstContentBudgetMs = int(genericDeadline.Milliseconds())
		rp.EstimatedPromptTokens, rp.RequestedMaxTokens = estimatedPromptTokens, requestedMaxTokens
		rp.RequiresVision, rp.HasTools = requiresVision, hasTools
		rp.BodyBytes = len(rawBody)
	}
	session := s.NewDispatchSession(DispatchRequest{
		Writer: w, Request: r, Model: model, PublicModel: publicModel, Body: inferenceBody,
		ConsumerKey: consumerKey, ConsumerLocation: consumerLocation,
		ReservedMicroUSD: reservedMicroUSD, TokenAdmission: tokenAdmission, ServiceReservation: serviceReservation,
		EstimatedPromptTokens: estimatedPromptTokens, RequestedMaxTokens: requestedMaxTokens,
		RequiresVision: requiresVision, VisionImageCount: inreq.CountMediaParts(parsed),
		Traits: registry.RequestTraits{
			HasTools: hasTools, RequiresToolConstraint: requiresToolConstraint,
			ToolChoiceMode: string(validatedMode), ToolChoiceName: toolChoiceName, ParallelToolCalls: parallelToolCalls,
		},
		ConsumerEndpoint: consumerEndpoint, RequestedStopSequences: requestedStopSequences,
		Stream: stream, MetadataDetails: inreq.MetadataDetailsFromRequest(r),
		Scope:                  dispatch.Scope{SelfRouteOnly: policy.enabled, PreferOwner: policy.prefer, OwnerAccountID: policy.ownerAccountID},
		AllowedProviderSerials: allowedProviderSerials, CachePlan: cachePlan, Timing: timing, Profile: rp,
		Deadline: genericDeadline, SpeculativeAt: s.firstContentHedgeDelay(model, estimatedPromptTokens, genericDeadline),
		ModelMaxContext: modelMaxContext, RefundReservation: refundReservation,
	})
	session.Run(r.Context())
}
