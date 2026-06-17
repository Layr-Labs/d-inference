package api

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
				total += 4
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

const penaltySafeProviderVersion = "0.6.7"

var visionPenaltyFields = []string{"repetition_penalty", "presence_penalty", "frequency_penalty"}

func bodyForProvider(rawBody []byte, requiresVision bool, provider *registry.Provider) []byte {
	if !requiresVision {
		return rawBody
	}
	if provider.Version != "" && !semverLess(provider.Version, penaltySafeProviderVersion) {
		return rawBody
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
