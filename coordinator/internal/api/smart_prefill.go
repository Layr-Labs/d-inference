package api

// Smart-prefill middleware for /v1/chat/completions.
//
// When the consumer opts in via `"smart_prefill": true` (or sets
// `"smart_prefill": { ... }` to override compressor, ratio, etc.), the
// coordinator dispatches the largest user/system message to a tiny-tier
// compressor provider, gets back a shortened prompt, and swaps it into
// the request before routing to the big-tier model. The big-tier model
// runs prefill on the shorter prompt — 2-5x lower TTFT at >90% task
// quality (see docs/smart-prefill.md).
//
// This file is intentionally tight: validation + selection + a single
// call into runCompression in compress.go. The compression endpoint and
// this middleware share the same dispatch path so retry, billing, and
// E2E encryption are guaranteed to behave identically.

import (
	"encoding/json"
	"net/http"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/store"
)

// smartPrefillSettings captures the consumer-supplied smart_prefill
// options. All fields optional — defaults come from the const block in
// compress.go.
type smartPrefillSettings struct {
	Enabled            bool    `json:"enabled,omitempty"`
	CompressorModel    string  `json:"compressor_model,omitempty"`
	TargetRatio        float64 `json:"target_ratio,omitempty"`
	MinKeepTokens      int     `json:"min_keep_tokens,omitempty"`
	MaxKeepTokens      int     `json:"max_keep_tokens,omitempty"`
	MinPromptTokens    int     `json:"min_prompt_tokens,omitempty"`
	PreserveBoundaries bool    `json:"preserve_boundaries,omitempty"`
}

// smartPrefillStats is what we surface back to the consumer via response
// headers so they can see what the middleware actually did.
type smartPrefillStats struct {
	Compressor       string
	OriginalTokens   int
	CompressedTokens int
}

// smartPrefillRequested returns true when the consumer asked for the
// middleware to run, accepting either a bare boolean or an object form.
func smartPrefillRequested(parsed map[string]any) bool {
	v, ok := parsed["smart_prefill"]
	if !ok {
		return false
	}
	switch x := v.(type) {
	case bool:
		return x
	case map[string]any:
		if enabled, ok := x["enabled"].(bool); ok {
			return enabled
		}
		// Object form with no explicit enabled flag → treat as enabled.
		return true
	}
	return false
}

// parseSmartPrefillSettings reads the `smart_prefill` field into the
// settings struct (returns an empty struct if absent or malformed).
func parseSmartPrefillSettings(parsed map[string]any) smartPrefillSettings {
	v, ok := parsed["smart_prefill"]
	if !ok {
		return smartPrefillSettings{}
	}
	if b, ok := v.(bool); ok {
		return smartPrefillSettings{Enabled: b}
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return smartPrefillSettings{}
	}
	s := smartPrefillSettings{Enabled: true}
	if v, ok := obj["compressor_model"].(string); ok {
		s.CompressorModel = v
	}
	if v, ok := obj["target_ratio"].(float64); ok {
		s.TargetRatio = v
	}
	if v, ok := intFromRequestValue(obj["min_keep_tokens"]); ok {
		s.MinKeepTokens = v
	}
	if v, ok := intFromRequestValue(obj["max_keep_tokens"]); ok {
		s.MaxKeepTokens = v
	}
	if v, ok := intFromRequestValue(obj["min_prompt_tokens"]); ok {
		s.MinPromptTokens = v
	}
	if v, ok := obj["preserve_boundaries"].(bool); ok {
		s.PreserveBoundaries = v
	}
	if v, ok := obj["enabled"].(bool); ok {
		s.Enabled = v
	}
	return s
}

// applySmartPrefill runs the compression middleware. It picks the longest
// `user` or `system` message in the request, compresses it, and writes
// the result back. Returns (stats, true) when compression actually
// happened, (zero, false) on any failure or skip — middleware is
// best-effort and never blocks the request.
func (s *Server) applySmartPrefill(r *http.Request, parsed map[string]any) (smartPrefillStats, bool) {
	settings := parseSmartPrefillSettings(parsed)
	if !settings.Enabled {
		return smartPrefillStats{}, false
	}

	// Strip the field so the compressed body we forward to the provider
	// doesn't carry our extension (provider backends would reject it).
	delete(parsed, "smart_prefill")

	idx, content := pickLongestMessage(parsed)
	if idx < 0 || content == "" {
		return smartPrefillStats{}, false
	}

	// Skip very short prompts — compression overhead would dominate.
	estTokens := approxTokens(content)
	minPrompt := settings.MinPromptTokens
	if minPrompt <= 0 {
		minPrompt = 2_000 // ≈ 8 KB; below this the round-trip isn't worth it
	}
	if estTokens < minPrompt {
		return smartPrefillStats{}, false
	}

	compressor := settings.CompressorModel
	if compressor == "" {
		compressor = defaultCompressorModel
	}
	if !s.registry.IsModelInCatalog(compressor) {
		s.logger.Debug("smart_prefill skipped: compressor not in catalog", "compressor", compressor)
		return smartPrefillStats{}, false
	}

	ratio := settings.TargetRatio
	if ratio <= 0 || ratio > 1 {
		ratio = defaultCompressionRatio
	}

	req := protocol.PromptCompressionRequestBody{
		CompressorModel:    compressor,
		Prompt:             content,
		TargetRatio:        ratio,
		MinKeepTokens:      settings.MinKeepTokens,
		MaxKeepTokens:      settings.MaxKeepTokens,
		PreserveBoundaries: settings.PreserveBoundaries,
	}
	rawBody, _ := json.Marshal(req)
	consumerKey := consumerKeyFromContext(r.Context())

	customRate, _, hasCustom := s.store.GetModelPrice("platform", compressor)
	var reservedMicroUSD int64
	if s.billing != nil {
		reservedMicroUSD = computeCompressorCost(compressor, estTokens, customRate, hasCustom)
		if err := s.ledger.Charge(consumerKey, reservedMicroUSD, "reserve:"+consumerKey); err != nil {
			// Insufficient funds for compression → silently fall through
			// to normal prefill. The chat handler will surface its own
			// 402 if the consumer also can't afford the inference.
			s.logger.Debug("smart_prefill skipped: insufficient funds for compressor",
				"consumer_key", consumerKey, "estimated_tokens", estTokens)
			return smartPrefillStats{}, false
		}
	}

	// refundCompression credits back the full reservation. Used on every
	// fall-through path that didn't actually apply the compressed prompt to
	// the consumer's request — including success-but-empty-result and
	// success-but-swap-failed. Without this we'd bill the consumer for
	// compression that they never benefit from. Best-effort: silent on
	// errors because we're already on a degraded code path.
	refundCompression := func(reason string) {
		if reservedMicroUSD > 0 && s.billing != nil {
			_ = s.store.Credit(consumerKey, reservedMicroUSD, store.LedgerRefund, "smart_prefill:"+reason)
		}
	}

	result, _, errMsg := s.runCompression(r, &req, rawBody, consumerKey,
		estTokens, reservedMicroUSD, customRate, hasCustom)
	if result == nil {
		refundCompression("compression_failed")
		s.logger.Info("smart_prefill failed, falling through to full prefill",
			"compressor", compressor,
			"original_tokens", estTokens,
			"error", errMsg,
		)
		return smartPrefillStats{}, false
	}

	if result.CompressedPrompt == "" {
		refundCompression("empty_result")
		s.logger.Warn("smart_prefill compressor returned empty prompt, falling through",
			"compressor", compressor)
		return smartPrefillStats{}, false
	}

	// Swap the compressed prompt back into the message.
	if !replaceMessageContent(parsed, idx, result.CompressedPrompt) {
		refundCompression("swap_failed")
		s.logger.Warn("smart_prefill swap failed (request shape changed?), falling through",
			"compressor", compressor)
		return smartPrefillStats{}, false
	}

	stats := smartPrefillStats{
		Compressor:       compressor,
		OriginalTokens:   int(result.Usage.OriginalTokens),
		CompressedTokens: int(result.Usage.CompressedTokens),
	}
	s.logger.Info("smart_prefill applied",
		"compressor", compressor,
		"original_tokens", stats.OriginalTokens,
		"compressed_tokens", stats.CompressedTokens,
	)
	return stats, true
}

// pickLongestMessage returns the (index, content) of the longest string-
// content user/system message in `messages`. Returns (-1, "") when no
// such message exists.
//
// We pick the longest because it dominates the prefill cost — compressing
// a 50-token chat turn is wasted overhead, compressing a 30k-token system
// prompt or RAG context is the whole point of smart_prefill.
func pickLongestMessage(parsed map[string]any) (int, string) {
	msgs, ok := parsed["messages"].([]any)
	if !ok {
		return -1, ""
	}
	bestIdx := -1
	bestLen := 0
	bestContent := ""
	for i, m := range msgs {
		obj, ok := m.(map[string]any)
		if !ok {
			continue
		}
		role, _ := obj["role"].(string)
		if role != "user" && role != "system" && role != "developer" {
			continue
		}
		content, ok := obj["content"].(string)
		if !ok {
			continue // skip multimodal / array-content messages for now
		}
		if len(content) > bestLen {
			bestIdx, bestLen, bestContent = i, len(content), content
		}
	}
	return bestIdx, bestContent
}

// replaceMessageContent overwrites messages[idx].content. Returns false
// if the cast fails (which would mean someone mutated the structure under
// us — bail rather than corrupt the request).
func replaceMessageContent(parsed map[string]any, idx int, newContent string) bool {
	msgs, ok := parsed["messages"].([]any)
	if !ok || idx < 0 || idx >= len(msgs) {
		return false
	}
	obj, ok := msgs[idx].(map[string]any)
	if !ok {
		return false
	}
	obj["content"] = newContent
	msgs[idx] = obj
	parsed["messages"] = msgs
	return true
}
