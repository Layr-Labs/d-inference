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
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

const (
	// inferenceTimeout is the maximum time to wait between chunks (streaming)
	// or for the full response (non-streaming). For streaming, the deadline
	// resets on each received chunk so long-running generations don't time out.
	// 10 minutes allows 32k tokens at ~55 tok/s on slower hardware.
	inferenceTimeout = 600 * time.Second

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

// errModelTooLarge is the dispatch error returned when providers serve the
// requested model but none of them has enough total memory to ever load it.
// Distinct from "no provider available" so the caller rejects fast instead of
// queuing for 120s — queueing can't help a model that will never fit.
const errModelTooLarge = "model too large for any available provider"

// dispatchOneProvider encrypts and sends an inference request to a single
// provider. It returns the pending request and provider on success, or an
// error string on failure. The excludeProviders set is updated on failure.
// selfRoutePolicy and its resolvers live in self_route.go.

func (s *Server) dispatchOneProvider(
	r *http.Request,
	model string,
	rawBody []byte,
	consumerKey string,
	consumerLocation *store.ProviderLocation,
	reservedMicroUSD int64,
	estimatedPromptTokens int,
	requestedMaxTokens int,
	allowedProviderSerials []string,
	isResponsesAPI bool,
	policy selfRoutePolicy,
	timing *registry.RequestTiming,
	excludeProviders map[string]struct{},
) (
	provider *registry.Provider,
	pr *registry.PendingRequest,
	decision registry.RoutingDecision,
	lastErr string,
	lastErrCode int,
) {
	requestID := uuid.New().String()
	pr = &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		ConsumerKey:            consumerKey,
		KeyID:                  keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:          keyLimitResetFromContext(r.Context()),
		ConsumerLocation:       consumerLocation,
		IsResponsesAPI:         isResponsesAPI,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		ReservedMicroUSD:       reservedMicroUSD,
		BaseReservedMicroUSD:   reservedMicroUSD,
		AllowedProviderSerials: allowedProviderSerials,
		SelfRouteOnly:          policy.enabled,
		OwnerAccountID:         policy.ownerAccountID,
		FreeSelfRoute:          policy.enabled,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan string, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
		Timing:                 timing,
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

	if s.billing != nil && !policy.enabled && !providerHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}

	// Free self-route requests are settled at zero cost (handleComplete), so
	// there is no reservation to top up for a provider's custom price.
	if s.billing != nil && !policy.enabled {
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

	encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
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
	pr.Timing.DispatchedAt = time.Now()

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
		total += approximateTokenCount(v)
	}
	if v, ok := parsed["input"]; ok {
		total += approximateTokenCount(v)
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
	s.ddIncr("billing.reservation_refunds", []string{"model:" + pr.Model})
	s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
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
	if explicitMaxTokens(parsed) > 0 {
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

	// Read the raw request body so we can forward it as-is to the provider.
	// We only parse minimally to extract model/stream/messages for routing.
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}

	var parsed map[string]any
	if err := json.Unmarshal(rawBody, &parsed); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return
	}

	// Per-key model allow-list enforcement (phase 3).
	if !s.keyModelAllowed(r.Context(), model) {
		writeJSON(w, http.StatusForbidden, errorResponse("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), withParam("model")))
		return
	}

	// Accept either chat completions format (messages) or Responses API
	// format (input). The provider's backend handles both natively.
	messages, _ := parsed["messages"].([]any)
	input := parsed["input"]
	if len(messages) == 0 && input == nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "messages or input is required"))
		return
	}

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist && stripProviderRoutingFields(parsed) {
		rawBody, _ = json.Marshal(parsed)
	}

	// "Use my own machine, for free" opt-in. The signal is the
	// X-Darkbloom-Route header (OpenAI-client-safe: invisible to the body
	// schema) OR a per-key hard ceiling. The header can only *request*
	// self-routing; it cannot name a machine — ownership is matched on the
	// coordinator-stamped provider AccountID, so nothing here is forgeable.
	policy := s.resolveSelfRoutePolicy(r)

	isResponsesAPI := input != nil && len(messages) == 0

	// Inject model-specific defaults from the registry: reasoning_parser
	// and max_tokens bound. Single DB lookup (cached for platform prices).
	maxOutputBound := defaultMaxOutputTokens
	if rec, err := s.store.GetModelRegistryRecord(model); err == nil {
		// Reasoning parser from runtime_parameters.
		if _, hasRP := parsed["reasoning_parser"]; !hasRP && rec.RuntimeParameters != nil {
			if rp, ok := rec.RuntimeParameters["reasoning_parser"]; ok {
				parsed["reasoning_parser"] = rp
				rawBody, _ = json.Marshal(parsed)
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
		rawBody, _ = json.Marshal(parsed)
	}

	stream, _ := parsed["stream"].(bool)
	estimatedPromptTokens := estimatePromptTokens(parsed)
	billingPromptTokens := estimateBillingPromptTokens(parsed)
	requestedMaxTokens := estimateRequestedMaxTokens(parsed)
	timing.ParsedAt = time.Now()

	if isResponsesAPI {
		providerParsed, err := responsesRequestToChatCompletions(parsed)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
			return
		}
		rawBody, _ = json.Marshal(providerParsed)
	}

	// Per-account token rate limiting (ITPM/OTPM) — the industry-standard
	// token throttle alongside RPM. Charged upfront from the input estimate
	// and the bounded max_tokens (OpenAI-style). Runs before the balance
	// reservation so a throttled request never touches billing.
	if !s.applyTokenRateLimit(w, r, estimatedPromptTokens, requestedMaxTokens) {
		return
	}

	// Pre-flight balance reservation — atomically debit the worst-case cost
	// using the byte-length upper bound for prompt tokens (guaranteed >=
	// actual tokens for any BPE tokenizer) plus max_tokens we just bounded
	// the generation to. The post-inference charge refunds any unused
	// portion. The routing estimate (estimatedPromptTokens, len/4) is kept
	// separate so scheduler capacity checks aren't over-inflated.
	var reservedMicroUSD int64
	// Self-route is free: skip the pre-flight balance reservation and the
	// per-key spend cap entirely. A zero-balance owner must never be blocked
	// from running on their own machine, and a self_route_only key never spends.
	if s.billing != nil && !policy.enabled {
		consumerKey := consumerKeyFromContext(r.Context())
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation so a
		// capped key never debits the account ledger.
		if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
			return
		}
		start := time.Now()
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
					"service temporarily unavailable — please retry"))
			}
			return
		}
		s.ddHistogram("billing.reserved_micro_usd", float64(reservedMicroUSD), []string{"model:" + model})
		s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reserve"})
	}
	timing.ReservedAt = time.Now()

	// Refund reservation on early errors (before inference starts).
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			consumerKey := consumerKeyFromContext(r.Context())
			start := time.Now()
			_ = s.store.Credit(consumerKey, reservedMicroUSD, store.LedgerRefund, "reservation_refund")
			s.ddIncr("billing.reservation_refunds", []string{"model:" + model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
		}
	}

	// Reject requests for models not in the catalog.
	if !s.registry.IsModelInCatalog(model) {
		refundReservation()
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", model), withParam("model")))
		return
	}

	// Self-route pre-flight: confirm the caller owns an online machine that can
	// serve this model, with precise errors and no fallback to the paid fleet.
	if policy.enabled {
		if s.selfRouteUnavailable(w, r, policy.ownerAccountID, model) {
			refundReservation()
			return
		}
	} else {
		// Pre-flight capacity check: can ANY provider serve this model right
		// now? If not, return 429 immediately rather than queueing for up to
		// 120s. OpenRouter treats 429 as "rate limited" (no uptime penalty) vs
		// 503 which counts as downtime. Fast 429s also preserve our TTFT
		// metrics. Self-route skips this fleet-wide gate — it queues on the
		// owner's machine instead (handled below).
		candidateCount, capacityRejections, modelTooLarge := s.registry.QuickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials...)
		if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
			// Providers serve this model but none can ever fit it — non-retryable.
			// Surface a clear 503 instead of a 429 the client would retry forever.
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q is too large for any currently available provider", model),
				withCode("model_unavailable")))
			return
		}
		if candidateCount == 0 && capacityRejections > 0 {
			// Providers exist for this model but ALL are at capacity.
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", model, retryAfter),
				withCode("rate_limit_exceeded")))
			return
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
	var (
		provider    *registry.Provider
		pr          *registry.PendingRequest
		requestID   string
		firstChunk  string
		lastErr     string
		lastErrCode int
		committed   bool
	)

	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)

	// Track providers that failed during retry so we don't dispatch to them again.
	excludeProviders := make(map[string]struct{})

	deadline := ttftDeadline(estimatedPromptTokens)
	speculativeAt := time.Duration(float64(deadline) * speculativeTimerRatio)

	for attempt := range maxDispatchAttempts {
		// Dispatch the primary provider.
		var dispatchErr string
		var dispatchErrCode int
		provider, pr, _, dispatchErr, dispatchErrCode = s.dispatchOneProvider(
			r, model, rawBody, consumerKey, consumerLocation, reservedMicroUSD,
			estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials,
			isResponsesAPI, policy, timing, excludeProviders,
		)
		if provider == nil {
			// No online provider has enough memory to ever fit this model.
			// Retrying and queueing are both pointless — reject immediately
			// with a clear, non-retryable error.
			if dispatchErr == errModelTooLarge {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
				lastErr = dispatchErr
				lastErrCode = dispatchErrCode
				break
			}

			// dispatchOneProvider may have found a provider but rejected it
			// (payout destination missing, insufficient funds, encryption
			// missing). In that case it already added the provider to
			// excludeProviders. If there may be more providers to try,
			// continue to the next attempt.
			providerWasRejected := dispatchErr != "no provider available"
			if providerWasRejected {
				lastErr = dispatchErr
				lastErrCode = dispatchErrCode
				continue
			}

			// On retry attempts, don't queue — if the only available
			// providers already failed, waiting 120s for one of them
			// to come back won't help. Break and return the last error.
			// Don't overwrite lastErr/lastErrCode from the real provider
			// error — preserve the original status code.
			if attempt > 0 {
				if lastErr == "" {
					lastErr = dispatchErr
					lastErrCode = dispatchErrCode
				}
				break
			}
			// No idle provider — try queueing.
			requestID = uuid.New().String()
			queuePR := &registry.PendingRequest{
				RequestID:              requestID,
				Model:                  model,
				ConsumerKey:            consumerKey,
				KeyID:                  keyIDFromContext(r.Context()),
				KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
				KeyLimitReset:          keyLimitResetFromContext(r.Context()),
				ConsumerLocation:       consumerLocation,
				IsResponsesAPI:         isResponsesAPI,
				EstimatedPromptTokens:  estimatedPromptTokens,
				RequestedMaxTokens:     requestedMaxTokens,
				ReservedMicroUSD:       reservedMicroUSD,
				BaseReservedMicroUSD:   reservedMicroUSD,
				AllowedProviderSerials: allowedProviderSerials,
				SelfRouteOnly:          policy.enabled,
				OwnerAccountID:         policy.ownerAccountID,
				FreeSelfRoute:          policy.enabled,
				AcceptedCh:             make(chan struct{}, 1),
				ChunkCh:                make(chan string, chunkBufferSize),
				CompleteCh:             make(chan protocol.UsageInfo, 1),
				ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
				Timing:                 timing,
			}
			queuedReq := &registry.QueuedRequest{
				RequestID:  requestID,
				Model:      model,
				Pending:    queuePR,
				ResponseCh: make(chan *registry.Provider, 1),
			}
			queuePR.Timing.QueuedAt = time.Now()
			if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
				s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:over_capacity"})
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				refundReservation()
				if policy.enabled {
					writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
						"your machine is at capacity — retry shortly", withCode("machine_busy")))
				} else {
					writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
						fmt.Sprintf("all providers for model %q are at capacity and queue is full", model),
						withCode("rate_limit_exceeded")))
				}
				return
			}
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:queued"})

			s.logger.Info("request queued, waiting for provider",
				"model", model,
				"attempt", attempt+1,
			)

			var err error
			provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
			if err != nil {
				if errors.Is(err, context.Canceled) {
					refundReservation()
					return
				}
				refundReservation()
				s.ddIncr("request_queue.timeout", []string{"model:" + model, "model_type:" + s.registry.ModelType(model)})
				retryAfter := s.estimateRetryAfter(model)
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				if policy.enabled {
					writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
						"your machine is at capacity (timed out waiting for a free slot) — retry shortly", withCode("machine_busy")))
				} else {
					writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
						fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", model),
						withCode("rate_limit_exceeded")))
				}
				return
			}
			// Queue assigned a provider; still need to dispatch.
			// Use the queue PR's channels.
			pr = queuePR
			requestID = pr.RequestID
			timing.RoutedAt = time.Now()

			// Log missing payout destination but don't skip — earnings
			// are credited to the provider's internal ledger and can be
			// withdrawn once they complete Stripe Connect onboarding.
			if s.billing != nil && !policy.enabled && !providerHasPayoutDestination(provider) {
				s.logger.Warn("queued provider missing payout destination, crediting to internal ledger",
					"request_id", requestID,
					"provider_id", provider.ID,
				)
			}

			// Custom pricing check — provider may charge more than the
			// platform rate. Reserve the additional amount now. Skipped for
			// free self-route, which settles at zero cost.
			if s.billing != nil && !policy.enabled {
				if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
					provider.RemovePending(requestID)
					s.registry.SetProviderIdle(provider.ID)
					excludeProviders[provider.ID] = struct{}{}
					if errors.Is(err, store.ErrInsufficientBalance) {
						s.logger.Warn("queued provider pricing exceeds balance, skipping",
							"request_id", requestID,
							"provider_id", provider.ID,
							"error", err,
						)
						lastErr = "insufficient funds for provider price"
						lastErrCode = http.StatusPaymentRequired
					} else {
						s.logger.Error("queued provider reservation failed (DB error)",
							"request_id", requestID,
							"provider_id", provider.ID,
							"error", err,
						)
						lastErr = "service temporarily unavailable — please retry"
						lastErrCode = http.StatusServiceUnavailable
					}
					continue
				}
			}
			// Perform E2E encryption and send the request.
			if provider.PublicKey == "" {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				excludeProviders[provider.ID] = struct{}{}
				lastErr = "no provider with E2E encryption"
				continue
			}
			providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
			if err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				excludeProviders[provider.ID] = struct{}{}
				lastErr = "provider public key invalid"
				continue
			}
			sessionKeys, err := e2e.GenerateSessionKeys()
			if err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				lastErr = "failed to generate session keys"
				continue
			}
			encrypted, err := e2e.Encrypt(rawBody, providerPubKey, sessionKeys)
			if err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				lastErr = "failed to encrypt request"
				continue
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
			// pr.ReservedMicroUSD was already set in the struct literal and may
			// have been increased by reserveAdditionalForProvider. Don't overwrite.
			data, _ := json.Marshal(wireMsg)
			if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.refundProviderExtra(pr)
				excludeProviders[provider.ID] = struct{}{}
				lastErr = "failed to send request to provider"
				continue
			}
			pr.Timing.DispatchedAt = time.Now()
		}
		requestID = pr.RequestID
		if timing.RoutedAt.IsZero() {
			timing.RoutedAt = time.Now()
		}
		s.ddIncr("routing.decisions", []string{"model:" + model, "outcome:selected"})
		s.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})

		s.logger.Info("inference request dispatched",
			"trace_id", requestIDFromContext(r.Context()),
			"request_id", requestID,
			"model", model,
			"provider_id", provider.ID,
			"stream", stream,
			"attempt", attempt+1,
		)

		s.logger.Info("dispatch_pool",
			"model", model,
			"ttft_deadline_ms", deadline.Milliseconds(),
			"speculative_at_ms", speculativeAt.Milliseconds(),
		)

		// ---- Speculative TTFT-aware first-chunk wait ----
		//
		// Phase 1: Wait for first chunk with speculative timer.
		// - If primary sends first chunk → commit.
		// - If primary sends accepted → extend to inferenceTimeout (model reload).
		// - If primary errors → retry immediately (sequential fallback).
		// - If speculative timer fires → dispatch backup and race.
		// - If full deadline expires → fail.

		speculativeTimer := time.NewTimer(speculativeAt)
		deadlineTimer := time.NewTimer(deadline)
		accepted := false

		select {
		case chunk, ok := <-pr.ChunkCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				firstChunk = chunk
				pr.Timing.FirstChunkAt = time.Now()
				committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					lastErr = errMsg.Error
					lastErrCode = errMsg.StatusCode
					provider = nil
					pr = nil
					continue
				default:
					committed = true
				}
			}

		case <-pr.AcceptedCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			accepted = true

		case errMsg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			lastErr = errMsg.Error
			lastErrCode = errMsg.StatusCode
			s.logger.Warn("provider failed, retrying",
				"request_id", requestID,
				"provider_id", provider.ID,
				"attempt", attempt+1,
				"error", errMsg.Error,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
				"provider failed, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			s.ddIncr("inference.dispatches", []string{"status:retry"})
			provider = nil
			pr = nil
			continue

		case <-speculativeTimer.C:
			deadlineTimer.Stop()
			// Primary is slow. Attempt speculative backup dispatch.
			s.ddIncr("inference.speculative_dispatch", []string{"model:" + model})

			backupExclude := make(map[string]struct{}, len(excludeProviders)+1)
			for id := range excludeProviders {
				backupExclude[id] = struct{}{}
			}
			backupExclude[provider.ID] = struct{}{}

			backupProvider, backupPR, _, _, _ := s.dispatchOneProvider(
				r, model, rawBody, consumerKey, consumerLocation, reservedMicroUSD,
				estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials,
				isResponsesAPI, policy, &registry.RequestTiming{ReceivedAt: timing.ReceivedAt},
				backupExclude,
			)

			if backupProvider == nil {
				// No backup available. Keep waiting for primary with remaining deadline.
				s.logger.Info("speculative_dispatch_no_backup",
					"request_id", requestID,
					"primary_provider", provider.ID,
				)
				remainingDeadline := time.NewTimer(deadline - speculativeAt)
				select {
				case chunk, ok := <-pr.ChunkCh:
					remainingDeadline.Stop()
					if ok {
						firstChunk = chunk
						pr.Timing.FirstChunkAt = time.Now()
						committed = true
					} else {
						select {
						case errMsg := <-pr.ErrorCh:
							excludeProviders[provider.ID] = struct{}{}
							s.cancelDispatch(provider, pr)
							lastErr = errMsg.Error
							lastErrCode = errMsg.StatusCode
							provider = nil
							pr = nil
							continue
						default:
							committed = true
						}
					}
				case <-pr.AcceptedCh:
					remainingDeadline.Stop()
					accepted = true
				case errMsg := <-pr.ErrorCh:
					remainingDeadline.Stop()
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					lastErr = errMsg.Error
					lastErrCode = errMsg.StatusCode
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
					}
					s.ddIncr("inference.dispatches", []string{"status:retry"})
					provider = nil
					pr = nil
					continue
				case <-remainingDeadline.C:
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					lastErr = "timeout waiting for first response"
					lastErrCode = http.StatusGatewayTimeout
					s.logger.Warn("provider timeout (no backup), retrying",
						"request_id", requestID,
						"provider_id", provider.ID,
						"attempt", attempt+1,
					)
					s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
						"provider first-chunk timeout",
						map[string]any{
							"provider_id": provider.ID,
							"attempt":     attempt + 1,
							"reason":      "first_chunk_timeout",
						})
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
					}
					s.ddIncr("inference.dispatches", []string{"status:timeout"})
					provider = nil
					pr = nil
					continue
				case <-r.Context().Done():
					remainingDeadline.Stop()
					s.cancelDispatch(provider, pr)
					refundReservation()
					return
				}
			} else {
				// Backup dispatched — race primary vs backup.
				s.logger.Info("speculative_dispatch",
					"request_id", requestID,
					"primary_provider", provider.ID,
					"backup_provider", backupProvider.ID,
					"ttft_deadline_ms", deadline.Milliseconds(),
					"speculative_at_ms", speculativeAt.Milliseconds(),
				)

				raceDeadline := time.NewTimer(deadline - speculativeAt)

				select {
				case chunk, ok := <-pr.ChunkCh:
					// Primary wins!
					raceDeadline.Stop()
					s.cancelDispatch(backupProvider, backupPR)
					if ok {
						firstChunk = chunk
						pr.Timing.FirstChunkAt = time.Now()
						committed = true
					} else {
						select {
						case errMsg := <-pr.ErrorCh:
							// Primary failed but we already cancelled backup.
							excludeProviders[provider.ID] = struct{}{}
							s.cancelDispatch(provider, pr)
							lastErr = errMsg.Error
							lastErrCode = errMsg.StatusCode
							provider = nil
							pr = nil
							continue
						default:
							committed = true
						}
					}

				case chunk, ok := <-backupPR.ChunkCh:
					// Backup wins!
					raceDeadline.Stop()
					s.cancelDispatch(provider, pr)
					s.ddIncr("inference.speculative_win", []string{"model:" + model})
					if ok {
						provider = backupProvider
						pr = backupPR
						requestID = pr.RequestID
						firstChunk = chunk
						pr.Timing.FirstChunkAt = time.Now()
						committed = true
					} else {
						select {
						case errMsg := <-backupPR.ErrorCh:
							// Backup failed too. Keep primary context for retry.
							excludeProviders[backupProvider.ID] = struct{}{}
							// Wait remaining deadline for primary.
							remainingPrimary := time.NewTimer(deadline - speculativeAt)
							select {
							case chunk, ok := <-pr.ChunkCh:
								remainingPrimary.Stop()
								if ok {
									firstChunk = chunk
									pr.Timing.FirstChunkAt = time.Now()
									committed = true
								} else {
									select {
									case errMsg2 := <-pr.ErrorCh:
										excludeProviders[provider.ID] = struct{}{}
										s.cancelDispatch(provider, pr)
										lastErr = errMsg2.Error
										lastErrCode = errMsg2.StatusCode
										provider = nil
										pr = nil
										continue
									default:
										committed = true
									}
								}
							case <-pr.AcceptedCh:
								remainingPrimary.Stop()
								accepted = true
							case <-remainingPrimary.C:
								excludeProviders[provider.ID] = struct{}{}
								s.cancelDispatch(provider, pr)
								lastErr = errMsg.Error
								lastErrCode = errMsg.StatusCode
								provider = nil
								pr = nil
								continue
							case <-r.Context().Done():
								remainingPrimary.Stop()
								s.cancelDispatch(provider, pr)
								refundReservation()
								return
							}
						default:
							// Backup channel closed with no error — treat as committed.
							s.cancelDispatch(provider, pr)
							provider = backupProvider
							pr = backupPR
							requestID = pr.RequestID
							committed = true
						}
					}

				case <-pr.AcceptedCh:
					// Primary accepted (model reload). Cancel backup, extend deadline.
					raceDeadline.Stop()
					s.cancelDispatch(backupProvider, backupPR)
					accepted = true

				case <-backupPR.AcceptedCh:
					// Backup accepted (model reload). Cancel primary, extend deadline.
					raceDeadline.Stop()
					s.cancelDispatch(provider, pr)
					provider = backupProvider
					pr = backupPR
					requestID = pr.RequestID
					accepted = true

				case errMsg := <-pr.ErrorCh:
					// Primary failed. Keep waiting for backup.
					raceDeadline.Stop()
					excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					// Wait for backup with remaining deadline.
					backupDeadline := time.NewTimer(deadline - speculativeAt)
					select {
					case chunk, ok := <-backupPR.ChunkCh:
						backupDeadline.Stop()
						_ = errMsg // used implicitly via excludeProviders
						if ok {
							provider = backupProvider
							pr = backupPR
							requestID = pr.RequestID
							firstChunk = chunk
							pr.Timing.FirstChunkAt = time.Now()
							committed = true
						} else {
							select {
							case errMsg2 := <-backupPR.ErrorCh:
								excludeProviders[backupProvider.ID] = struct{}{}
								s.cancelDispatch(backupProvider, backupPR)
								lastErr = errMsg2.Error
								lastErrCode = errMsg2.StatusCode
								provider = nil
								pr = nil
								continue
							default:
								provider = backupProvider
								pr = backupPR
								requestID = pr.RequestID
								committed = true
							}
						}
					case <-backupPR.AcceptedCh:
						backupDeadline.Stop()
						provider = backupProvider
						pr = backupPR
						requestID = pr.RequestID
						accepted = true
					case errMsg2 := <-backupPR.ErrorCh:
						backupDeadline.Stop()
						excludeProviders[backupProvider.ID] = struct{}{}
						s.cancelDispatch(backupProvider, backupPR)
						lastErr = errMsg2.Error
						lastErrCode = errMsg2.StatusCode
						provider = nil
						pr = nil
						continue
					case <-backupDeadline.C:
						excludeProviders[backupProvider.ID] = struct{}{}
						s.cancelDispatch(backupProvider, backupPR)
						lastErr = "timeout waiting for first response (backup)"
						lastErrCode = http.StatusGatewayTimeout
						if s.metrics != nil {
							s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
						}
						s.ddIncr("inference.dispatches", []string{"status:timeout"})
						provider = nil
						pr = nil
						continue
					case <-r.Context().Done():
						backupDeadline.Stop()
						s.cancelDispatch(backupProvider, backupPR)
						refundReservation()
						return
					}

				case errMsg := <-backupPR.ErrorCh:
					// Backup failed. Keep waiting for primary.
					raceDeadline.Stop()
					excludeProviders[backupProvider.ID] = struct{}{}
					s.cancelDispatch(backupProvider, backupPR)
					_ = errMsg
					primaryDeadline := time.NewTimer(deadline - speculativeAt)
					select {
					case chunk, ok := <-pr.ChunkCh:
						primaryDeadline.Stop()
						if ok {
							firstChunk = chunk
							pr.Timing.FirstChunkAt = time.Now()
							committed = true
						} else {
							select {
							case errMsg2 := <-pr.ErrorCh:
								excludeProviders[provider.ID] = struct{}{}
								s.cancelDispatch(provider, pr)
								lastErr = errMsg2.Error
								lastErrCode = errMsg2.StatusCode
								provider = nil
								pr = nil
								continue
							default:
								committed = true
							}
						}
					case <-pr.AcceptedCh:
						primaryDeadline.Stop()
						accepted = true
					case errMsg2 := <-pr.ErrorCh:
						primaryDeadline.Stop()
						excludeProviders[provider.ID] = struct{}{}
						s.cancelDispatch(provider, pr)
						lastErr = errMsg2.Error
						lastErrCode = errMsg2.StatusCode
						provider = nil
						pr = nil
						continue
					case <-primaryDeadline.C:
						excludeProviders[provider.ID] = struct{}{}
						s.cancelDispatch(provider, pr)
						lastErr = "timeout waiting for first response"
						lastErrCode = http.StatusGatewayTimeout
						if s.metrics != nil {
							s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
						}
						s.ddIncr("inference.dispatches", []string{"status:timeout"})
						provider = nil
						pr = nil
						continue
					case <-r.Context().Done():
						primaryDeadline.Stop()
						s.cancelDispatch(provider, pr)
						refundReservation()
						return
					}

				case <-raceDeadline.C:
					// Both missed deadline.
					s.cancelDispatch(provider, pr)
					s.cancelDispatch(backupProvider, backupPR)
					excludeProviders[provider.ID] = struct{}{}
					excludeProviders[backupProvider.ID] = struct{}{}
					lastErr = "timeout waiting for first response (both providers)"
					lastErrCode = http.StatusGatewayTimeout
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
					}
					s.ddIncr("inference.dispatches", []string{"status:timeout"})
					provider = nil
					pr = nil
					continue

				case <-r.Context().Done():
					raceDeadline.Stop()
					s.cancelDispatch(provider, pr)
					s.cancelDispatch(backupProvider, backupPR)
					refundReservation()
					return
				}
			}

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			lastErr = "timeout waiting for first response"
			lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout (full deadline), retrying",
				"request_id", requestID,
				"provider_id", provider.ID,
				"attempt", attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			provider = nil
			pr = nil
			continue

		case <-r.Context().Done():
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			s.cancelDispatch(provider, pr)
			refundReservation()
			return
		}

		// Provider accepted or sent first chunk — commit to this provider.
		// If only accepted (no chunk yet), wait for the first chunk with
		// the full inference timeout since the backend may be reloading.
		if accepted && !committed {
			chunkTimer := time.NewTimer(inferenceTimeout)
			select {
			case chunk, ok := <-pr.ChunkCh:
				chunkTimer.Stop()
				if ok {
					firstChunk = chunk
					pr.Timing.FirstChunkAt = time.Now()
					committed = true
				} else {
					// Closed — check for error. Use a short grace
					// period instead of a non-blocking default to
					// close the race where Go's select picks the
					// ChunkCh close before the ErrorCh value (sent
					// by the provider handler before closing ChunkCh).
					select {
					case errMsg := <-pr.ErrorCh:
						excludeProviders[provider.ID] = struct{}{}
						s.cancelDispatch(provider, pr)
						lastErr = errMsg.Error
						lastErrCode = errMsg.StatusCode
						s.logger.Warn("provider failed after accepting request, retrying",
							"request_id", requestID,
							"provider_id", provider.ID,
							"attempt", attempt+1,
							"error", errMsg.Error,
						)
						s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
							"provider failed after accepting request, retrying",
							map[string]any{
								"provider_id": provider.ID,
								"attempt":     attempt + 1,
								"reason":      "provider_error",
								"status_code": errMsg.StatusCode,
							})
						if s.metrics != nil {
							s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
						}
						s.ddIncr("inference.dispatches", []string{"status:retry"})
						provider = nil
						pr = nil
						continue
					case <-time.After(50 * time.Millisecond):
						committed = true
					}
				}
			case errMsg := <-pr.ErrorCh:
				chunkTimer.Stop()
				excludeProviders[provider.ID] = struct{}{}
				s.cancelDispatch(provider, pr)
				lastErr = errMsg.Error
				lastErrCode = errMsg.StatusCode
				s.logger.Warn("provider failed after accepting request, retrying",
					"request_id", requestID,
					"provider_id", provider.ID,
					"attempt", attempt+1,
					"error", errMsg.Error,
				)
				s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
					"provider failed after accepting request, retrying",
					map[string]any{
						"provider_id": provider.ID,
						"attempt":     attempt + 1,
						"reason":      "provider_error",
						"status_code": errMsg.StatusCode,
					})
				if s.metrics != nil {
					s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
				}
				s.ddIncr("inference.dispatches", []string{"status:retry"})
				provider = nil
				pr = nil
				continue
			case <-chunkTimer.C:
				excludeProviders[provider.ID] = struct{}{}
				s.cancelDispatch(provider, pr)
				lastErr = "provider accepted but timed out before first chunk"
				lastErrCode = http.StatusGatewayTimeout
				s.logger.Warn("provider timed out after accepting request, retrying",
					"request_id", requestID,
					"provider_id", provider.ID,
					"attempt", attempt+1,
				)
				s.emitRequest(r.Context(), protocol.SeverityWarn, requestID,
					"provider accepted timeout",
					map[string]any{
						"provider_id": provider.ID,
						"attempt":     attempt + 1,
						"reason":      "accepted_timeout",
					})
				if s.metrics != nil {
					s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
				}
				s.ddIncr("inference.dispatches", []string{"status:timeout"})
				provider = nil
				pr = nil
				continue
			case <-r.Context().Done():
				s.cancelDispatch(provider, pr)
				refundReservation()
				return
			}
		}

		break
	}

	if !committed {
		refundReservation()
		statusCode := lastErrCode
		if statusCode == 0 {
			// Distinguish capacity exhaustion (429) from genuine unavailability (503).
			// A quick capacity check tells us if providers exist but are full.
			_, capRej, _ := s.registry.QuickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials...)
			if capRej > 0 {
				statusCode = http.StatusTooManyRequests
			} else {
				statusCode = http.StatusServiceUnavailable
			}
		}
		s.emitRequest(r.Context(), protocol.SeverityError, requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", maxDispatchAttempts),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     maxDispatchAttempts,
				"status_code": statusCode,
				"last_error":  lastErr,
			})
		if s.metrics != nil {
			s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "failure"})
		}
		s.ddIncr("inference.dispatches", []string{"status:failure"})
		if statusCode == http.StatusTooManyRequests {
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			writeJSON(w, statusCode, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers at capacity after %d attempt(s): %s", maxDispatchAttempts, lastErr),
				withCode("rate_limit_exceeded")))
		} else {
			writeJSON(w, statusCode, errorResponse("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", maxDispatchAttempts, lastErr)))
		}
		return
	}
	if s.metrics != nil {
		s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "success"})
	}
	s.ddIncr("inference.dispatches", []string{"status:success"})

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
			ParseUs    int64 `json:"parse_us"`
			ReserveUs  int64 `json:"reserve_us"`
			RouteUs    int64 `json:"route_us"`
			QueueUs    int64 `json:"queue_us"`
			EncryptUs  int64 `json:"encrypt_us"`
			DispatchUs int64 `json:"dispatch_us"`
			ProviderUs int64 `json:"provider_us"`
		}
		tj := timingJSON{}
		if !timing.ParsedAt.IsZero() {
			tj.ParseUs = timing.ParsedAt.Sub(timing.ReceivedAt).Microseconds()
		}
		if !timing.ReservedAt.IsZero() && !timing.ParsedAt.IsZero() {
			tj.ReserveUs = timing.ReservedAt.Sub(timing.ParsedAt).Microseconds()
		}
		if !timing.RoutedAt.IsZero() && !timing.ReservedAt.IsZero() {
			tj.RouteUs = timing.RoutedAt.Sub(timing.ReservedAt).Microseconds()
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

	// When this function returns (consumer disconnect, timeout, or completion),
	// send a cancel to the provider so it stops generating tokens.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	if stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	}
}

// handleStreamingResponseWithFirstChunk streams SSE chunks to the consumer.
// If firstChunk is non-empty, it is written before reading further chunks
// from the channel. This allows the dispatch loop to "peek" at the first
// chunk for retry decisions without losing it.
func (s *Server) handleStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
	if pr.IsResponsesAPI {
		s.handleResponsesStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
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

	// Write the first chunk that was already consumed during dispatch.
	if firstChunk != "" {
		if strings.Contains(firstChunk, `"response.created"`) || strings.Contains(firstChunk, `"response.output_text.delta"`) {
			sawResponsesAPI = true
		}
		if !sawResponsesAPI {
			firstChunk = normalizeSSEChunk(firstChunk)
		}
		fmt.Fprintf(w, "%s\n\n", firstChunk)
		flusher.Flush()
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
					fmt.Fprintf(w, "data: {\"error\":{\"message\":\"provider ended without completion\",\"type\":\"provider_error\"}}\n\n")
					flusher.Flush()
					return
				}
				// Channel closed — inference complete.
				// For Responses API streams, the provider already sent
				// "response.completed" as the terminal event. Adding
				// extra chunks would break SDK parsers.
				if !sawResponsesAPI {
					// Chat completions format: append SE signature + [DONE].
					if pr.SESignature != "" {
						sigEvent, _ := json.Marshal(map[string]any{
							"choices":       []any{},
							"se_signature":  pr.SESignature,
							"response_hash": pr.ResponseHash,
						})
						fmt.Fprintf(w, "data: %s\n\n", sigEvent)
						flusher.Flush()
					}
					fmt.Fprint(w, "data: [DONE]\n\n")
					flusher.Flush()
				}
				return
			}
			if !sawResponsesAPI {
				if strings.Contains(chunk, `"response.created"`) || strings.Contains(chunk, `"response.output_text.delta"`) {
					sawResponsesAPI = true
				}
			}
			if !sawResponsesAPI {
				chunk = normalizeSSEChunk(chunk)
			}
			fmt.Fprintf(w, "%s\n\n", chunk)
			flusher.Flush()

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
			fmt.Fprintf(w, "data: {\"error\":{\"message\":\"request timed out\",\"type\":\"timeout\"}}\n\n")
			flusher.Flush()
			return

		case <-r.Context().Done():
			return
		}
	}
}

func writeResponsesSSE(w http.ResponseWriter, flusher http.Flusher, event map[string]any) {
	data, err := json.Marshal(event)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", data)
	flusher.Flush()
}

func (s *Server) handleResponsesStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
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
	writeResponsesSSE(w, flusher, map[string]any{
		"type": "response.created",
		"response": map[string]any{
			"id":           responseID,
			"created_at":   createdAt,
			"model":        pr.Model,
			"service_tier": nil,
		},
	})

	chunks := make([]string, 0, 16)
	if firstChunk != "" {
		chunks = append(chunks, firstChunk)
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
				default:
				}
				if !completed && s.refundReservedBalance(pr, "provider_incomplete:"+pr.RequestID) {
					writeResponsesSSE(w, flusher, map[string]any{
						"type":            "error",
						"sequence_number": 0,
						"error": map[string]any{
							"type":    "provider_error",
							"code":    "provider_error",
							"message": "provider ended without completion",
							"param":   nil,
						},
					})
					return
				}
				msg := extractMessage(chunks)
				writeResponsesStreamOutput(w, flusher, pr, responseID, createdAt, msg, usage)
				return
			}
			chunks = append(chunks, chunk)
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
			writeResponsesSSE(w, flusher, map[string]any{
				"type":            "error",
				"sequence_number": 0,
				"error": map[string]any{
					"type":    "provider_error",
					"code":    "provider_error",
					"message": errMsg.Error,
					"param":   nil,
				},
			})
			return

		case <-timer.C:
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			writeResponsesSSE(w, flusher, map[string]any{
				"type":            "error",
				"sequence_number": 0,
				"error": map[string]any{
					"type":    "timeout",
					"code":    "timeout",
					"message": "request timed out",
					"param":   nil,
				},
			})
			return

		case <-r.Context().Done():
			return
		}
	}
}

func writeResponsesStreamOutput(w http.ResponseWriter, flusher http.Flusher, pr *registry.PendingRequest, responseID string, createdAt int64, msg extractedMessage, usage protocol.UsageInfo) {
	outputIndex := 0
	if msg.Reasoning != "" {
		itemID := responseItemID("rs", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":              "reasoning",
				"id":                itemID,
				"encrypted_content": nil,
			},
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_part.added",
			"item_id":       itemID,
			"summary_index": 0,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_text.delta",
			"item_id":       itemID,
			"summary_index": 0,
			"delta":         msg.Reasoning,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":          "response.reasoning_summary_part.done",
			"item_id":       itemID,
			"summary_index": 0,
		})
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":              "reasoning",
				"id":                itemID,
				"encrypted_content": nil,
			},
		})
		outputIndex++
	}

	if msg.Content != "" || len(msg.ToolCalls) == 0 {
		itemID := responseItemID("msg", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":  "message",
				"id":    itemID,
				"phase": nil,
			},
		})
		if msg.Content != "" {
			writeResponsesSSE(w, flusher, map[string]any{
				"type":         "response.output_text.delta",
				"item_id":      itemID,
				"output_index": outputIndex,
				"delta":        msg.Content,
			})
		}
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":  "message",
				"id":    itemID,
				"phase": nil,
			},
		})
		outputIndex++
	}

	for _, tc := range msg.ToolCalls {
		fn, _ := tc["function"].(map[string]any)
		callID, _ := tc["id"].(string)
		if callID == "" {
			callID = responseItemID("call", pr.RequestID, outputIndex)
		}
		name, _ := fn["name"].(string)
		args, _ := fn["arguments"].(string)
		itemID := responseItemID("fc", pr.RequestID, outputIndex)
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.added",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        itemID,
				"call_id":   callID,
				"name":      name,
				"arguments": "",
			},
		})
		if args != "" {
			writeResponsesSSE(w, flusher, map[string]any{
				"type":         "response.function_call_arguments.delta",
				"item_id":      itemID,
				"output_index": outputIndex,
				"delta":        args,
			})
		}
		writeResponsesSSE(w, flusher, map[string]any{
			"type":         "response.output_item.done",
			"output_index": outputIndex,
			"item": map[string]any{
				"type":      "function_call",
				"id":        itemID,
				"call_id":   callID,
				"name":      name,
				"arguments": args,
				"status":    "completed",
			},
		})
		outputIndex++
	}

	reasoningTokens := resolveReasoningTokens(usage, msg.Reasoning)
	writeResponsesSSE(w, flusher, map[string]any{
		"type": "response.completed",
		"response": map[string]any{
			"id":                 responseID,
			"created_at":         createdAt,
			"model":              pr.Model,
			"incomplete_details": nil,
			"usage":              buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens),
			"service_tier":       nil,
		},
	})
}

// handleNonStreamingResponseWithFirstChunk collects all chunks from the
// provider and assembles them into a single OpenAI-compatible JSON response.
// If firstChunk is non-empty, it is prepended to the collected chunks.
func (s *Server) handleNonStreamingResponseWithFirstChunk(w http.ResponseWriter, r *http.Request, pr *registry.PendingRequest, firstChunk string) {
	ctx, cancel := context.WithTimeout(r.Context(), inferenceTimeout)
	defer cancel()

	var chunks []string
	if firstChunk != "" {
		chunks = append(chunks, firstChunk)
	}

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if !ok {
				select {
				case errMsg, ok := <-pr.ErrorCh:
					if ok && errMsg.Error != "" {
						s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
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
									writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
									return
								}
								completeUsage = u
							case <-ctx.Done():
								s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
								writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
								return
							}
							if objType == "chat.completion" {
								normalizeCompleteChatResponse(obj, pr.Model)
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
									respObj := chatCompletionToResponses(chatResp, pr.Model, pr.SESignature, pr.ResponseHash)
									writeJSON(w, http.StatusOK, respObj)
									return
								}
							}
							if pr.SESignature != "" {
								obj["se_signature"] = pr.SESignature
								obj["response_hash"] = pr.ResponseHash
							}
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
						writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "provider ended without completion"))
						return
					}
					var resp any
					if pr.IsResponsesAPI {
						resp = buildResponsesResponse(pr.RequestID, pr.Model, msg, usage, pr.SESignature, pr.ResponseHash)
					} else {
						resp = buildNonStreamingResponse(pr.RequestID, pr.Model, msg, usage, pr.SESignature, pr.ResponseHash)
					}
					writeJSON(w, http.StatusOK, resp)
				case <-ctx.Done():
					s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
					writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "timed out waiting for usage info"))
				}
				return
			}
			chunks = append(chunks, chunk)

		case errMsg, ok := <-pr.ErrorCh:
			if !ok {
				continue
			}
			s.refundReservedBalance(pr, "provider_error:"+pr.RequestID)
			statusCode := errMsg.StatusCode
			if statusCode == 0 {
				statusCode = http.StatusBadGateway
			}
			writeJSON(w, statusCode, errorResponse("provider_error", errMsg.Error))
			return

		case <-ctx.Done():
			s.refundReservedBalance(pr, "provider_timeout:"+pr.RequestID)
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "request timed out"))
			return
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
	Content   string           `json:"content"`
	Reasoning string           `json:"reasoning,omitempty"`
	ToolCalls []map[string]any `json:"tool_calls,omitempty"`
}

// extractMessage parses SSE data lines and reconstructs the full assistant
// message from streaming chunks, including content, reasoning, and tool_calls.
func extractMessage(chunks []string) extractedMessage {
	var contentBuilder strings.Builder
	var reasoningBuilder strings.Builder
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
	msg := extractedMessage{Content: content, Reasoning: reasoning}
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
			"type": "message",
			"role": "assistant",
			"id":   responseItemID("msg", requestID, index),
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
		})
		index++
	}
	return output
}

func buildResponsesResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, seSignature, responseHash string) types.ResponsesResponse {
	reasoningTokens := resolveReasoningTokens(usage, msg.Reasoning)
	resp := types.ResponsesResponse{
		ID:        "resp_" + strings.ReplaceAll(requestID, "-", ""),
		Object:    "response",
		CreatedAt: time.Now().Unix(),
		Model:     model,
		Output:    appendResponsesOutputItems(nil, requestID, msg),
		Usage:     buildResponsesUsage(uint64(usage.PromptTokens), uint64(usage.CompletionTokens), reasoningTokens),
	}
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
	if seSignature != "" {
		r.SESignature = seSignature
		r.ResponseHash = responseHash
	}
	return r
}

func buildNonStreamingResponse(requestID, model string, msg extractedMessage, usage protocol.UsageInfo, seSignature, responseHash string) types.ChatCompletionResponse {
	message := types.ChatCompletionMessage{
		Role:    "assistant",
		Content: msg.Content,
	}
	if msg.Reasoning != "" {
		message.Reasoning = msg.Reasoning
	}

	finishReason := "stop"
	if len(msg.ToolCalls) > 0 {
		message.ToolCalls = msg.ToolCalls
		finishReason = "tool_calls"
	}

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
func (s *Server) handleListModels(w http.ResponseWriter, r *http.Request) {
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
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}

	data := make([]types.ModelEntry, 0, len(models))
	for _, m := range models {
		cm, inCatalog := catalogByID[m.ID]
		if len(catalogByID) > 0 && !inCatalog {
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

	writeJSON(w, http.StatusOK, types.ModelListResponse{
		Object: "list",
		Data:   data,
	})
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
		Status:    "ok",
		Providers: s.registry.ProviderCount(),
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
			entries = append(entries, payments.UsageEntry{
				JobID:            jobID,
				Model:            u.Model,
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
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}

	var parsed map[string]any
	if err := json.Unmarshal(rawBody, &parsed); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	model, _ := parsed["model"].(string)
	if model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return
	}
	// Per-key model allow-list enforcement (phase 3).
	if !s.keyModelAllowed(r.Context(), model) {
		writeJSON(w, http.StatusForbidden, errorResponse("model_not_allowed",
			fmt.Sprintf("this API key is not permitted to use model %q", model), withParam("model")))
		return
	}
	if !s.registry.IsModelInCatalog(model) {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found",
			fmt.Sprintf("model %q is not available — see /v1/models for supported models", model), withParam("model")))
		return
	}

	allowedProviderSerials, hasProviderAllowlist, err := parseProviderSerialAllowlist(parsed)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if hasProviderAllowlist {
		stripProviderRoutingFields(parsed)
	}

	// "Use my own machine, for free" opt-in (see handleChatCompletions).
	policy := s.resolveSelfRoutePolicy(r)

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

	// Inject the endpoint so the provider knows which local path to forward to.
	parsed["endpoint"] = endpoint

	// Per-account token rate limiting (ITPM/OTPM), before the reservation.
	if !s.applyTokenRateLimit(w, r, estimatedPromptTokens, requestedMaxTokens) {
		return
	}

	// Pre-flight balance reservation — same worst-case-cost reservation as
	// handleChatCompletions, using the byte-length upper bound for prompt
	// tokens so the reservation always covers actual cost.
	consumerKey := consumerKeyFromContext(r.Context())
	consumerLocation := s.requestLocation(r)
	var reservedMicroUSD int64
	// Self-route is free: skip the reservation and per-key spend cap.
	if s.billing != nil && !policy.enabled {
		reservedMicroUSD = s.reservationCost(model, billingPromptTokens, requestedMaxTokens)
		// Per-key spend cap (phase 1) — checked before the reservation.
		if msg, ok := s.checkKeySpendCap(r.Context(), reservedMicroUSD); !ok {
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_quota", msg, withCode("insufficient_quota")))
			return
		}
		start := time.Now()
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this request — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("balance reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
					"service temporarily unavailable — please retry"))
			}
			return
		}
		s.ddHistogram("billing.reserved_micro_usd", float64(reservedMicroUSD), []string{"model:" + model})
		s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reserve"})
	}
	refundReservation := func() {
		if reservedMicroUSD > 0 {
			start := time.Now()
			_ = s.store.Credit(consumerKey, reservedMicroUSD, store.LedgerRefund, "reservation_refund")
			s.ddIncr("billing.reservation_refunds", []string{"model:" + model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:reservation_refund"})
		}
	}

	// Self-route pre-flight (precise errors, no paid fallback); otherwise the
	// fleet-wide capacity 429 (same logic as handleChatCompletions).
	if policy.enabled {
		if s.selfRouteUnavailable(w, r, policy.ownerAccountID, model) {
			refundReservation()
			return
		}
	} else {
		candidateCount, capacityRejections, modelTooLarge := s.registry.QuickCapacityCheck(model, estimatedPromptTokens, requestedMaxTokens, allowedProviderSerials...)
		if candidateCount == 0 && capacityRejections == 0 && modelTooLarge > 0 {
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q is too large for any currently available provider", model),
				withCode("model_unavailable")))
			return
		}
		if candidateCount == 0 && capacityRejections > 0 {
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:capacity_429"})
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers for model %q are at capacity — retry after %ds", model, retryAfter),
				withCode("rate_limit_exceeded")))
			return
		}
	}

	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		ConsumerKey:            consumerKey,
		KeyID:                  keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:       keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:          keyLimitResetFromContext(r.Context()),
		ConsumerLocation:       consumerLocation,
		AllowedProviderSerials: allowedProviderSerials,
		SelfRouteOnly:          policy.enabled,
		OwnerAccountID:         policy.ownerAccountID,
		FreeSelfRoute:          policy.enabled,
		EstimatedPromptTokens:  estimatedPromptTokens,
		RequestedMaxTokens:     requestedMaxTokens,
		ReservedMicroUSD:       reservedMicroUSD,
		BaseReservedMicroUSD:   reservedMicroUSD,
		AcceptedCh:             make(chan struct{}, 1),
		ChunkCh:                make(chan string, chunkBufferSize),
		CompleteCh:             make(chan protocol.UsageInfo, 1),
		ErrorCh:                make(chan protocol.InferenceErrorMessage, 1),
	}

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

		if s.billing != nil && !policy.enabled && !providerHasPayoutDestination(provider) {
			s.logger.Warn("provider missing payout destination, crediting to internal ledger",
				"provider_id", provider.ID)
		}

		// Custom pricing check — provider may charge more than the platform
		// rate. Skipped for free self-route, which settles at zero cost.
		if s.billing != nil && !policy.enabled {
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
		// No online provider can physically fit this model — queueing/retrying
		// can't help, so fast-fail with a clear, non-retryable error instead of
		// blocking for 120s then 503-ing. Mirrors the streaming dispatch path.
		if decision.CandidateCount == 0 && decision.CapacityRejections == 0 && decision.ModelTooLargeRejections > 0 {
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:model_too_large"})
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("model_unavailable",
				fmt.Sprintf("model %q is too large for any currently available provider", model),
				withCode("model_unavailable")))
			return
		}
		queuedReq := &registry.QueuedRequest{
			RequestID:  requestID,
			Model:      model,
			Pending:    pr,
			ResponseCh: make(chan *registry.Provider, 1),
		}
		if err := s.registry.Queue().Enqueue(queuedReq); err != nil {
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:over_capacity"})
			if policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity and queue is full", model),
					withCode("rate_limit_exceeded")))
			}
			return
		}
		s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:queued"})
		provider, err = s.registry.Queue().WaitForProviderContext(r.Context(), queuedReq)
		if err != nil {
			if errors.Is(err, context.Canceled) {
				refundReservation()
				return
			}
			retryAfter := s.estimateRetryAfter(model)
			w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
			refundReservation()
			if policy.enabled {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("machine_busy",
					"your machine is at capacity (timed out waiting for a free slot) — retry shortly", withCode("machine_busy")))
			} else {
				writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
					fmt.Sprintf("all providers for model %q are at capacity (queue timeout)", model),
					withCode("rate_limit_exceeded")))
			}
			return
		}
		decision = queuedReq.Decision
	}
	s.ddIncr("routing.decisions", []string{"model:" + model, "model_type:" + s.registry.ModelType(model), "outcome:selected"})
	s.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	s.ddHistogram("routing.cost_ms", decision.CostMs, []string{"model:" + model, "provider_id:" + provider.ID})
	if decision.EffectiveTPS > 0 {
		s.ddGauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})
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
	if s.billing != nil && !policy.enabled && !providerHasPayoutDestination(provider) {
		s.logger.Warn("provider missing payout destination, crediting to internal ledger",
			"provider_id", provider.ID)
	}
	// Free self-route settles at zero cost — no provider-price top-up.
	if s.billing != nil && !policy.enabled {
		if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
			cleanupPending()
			refundExtra()
			refundReservation()
			if errors.Is(err, store.ErrInsufficientBalance) {
				writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_funds",
					"your balance is too low for this provider price — add funds at /billing or lower max_tokens", withCode("insufficient_quota")))
			} else {
				s.logger.Error("provider reservation failed (DB error)", "consumer_key", consumerKey, "error", err)
				writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
					"service temporarily unavailable — please retry"))
			}
			return
		}
	}

	inferenceBody, _ := json.Marshal(parsed)

	if provider.PublicKey == "" {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("encryption_required",
			"no provider with E2E encryption available"))
		return
	}

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "provider public key invalid"))
		return
	}

	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to generate session keys"))
		return
	}

	encrypted, err := e2e.Encrypt(inferenceBody, providerPubKey, sessionKeys)
	if err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusInternalServerError, errorResponse("encryption_error", "failed to encrypt request"))
		return
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

	data, _ := json.Marshal(wireMsg)
	if err := provider.Conn.Write(r.Context(), websocket.MessageText, data); err != nil {
		cleanupPending()
		refundExtra()
		refundReservation()
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
	genericDeadline := ttftDeadline(estimatedPromptTokens)
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
			committed = true
		} else {
			select {
			case errMsg := <-pr.ErrorCh:
				provider.RemovePending(requestID)
				s.registry.SetProviderIdle(provider.ID)
				s.sendProviderCancel(provider, requestID)
				refundExtra()
				refundReservation()
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
		writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "provider did not respond within TTFT deadline"))
		return
	case <-r.Context().Done():
		ttftTimer.Stop()
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
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
				committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					provider.RemovePending(requestID)
					s.registry.SetProviderIdle(provider.ID)
					s.sendProviderCancel(provider, requestID)
					refundExtra()
					refundReservation()
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
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("timeout", "provider accepted but timed out before first chunk"))
			return
		case <-r.Context().Done():
			chunkTimer.Stop()
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
			s.sendProviderCancel(provider, requestID)
			refundExtra()
			refundReservation()
			return
		}
	}

	if !committed {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
		refundExtra()
		refundReservation()
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_error", "failed to get first chunk from provider"))
		return
	}

	// When this function returns (consumer disconnect, timeout, or
	// completion), tell the provider to stop generating. Without this the
	// provider keeps producing tokens into a buffered channel until the
	// buffer fills, wasting GPU cycles.
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	if stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunk)
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
