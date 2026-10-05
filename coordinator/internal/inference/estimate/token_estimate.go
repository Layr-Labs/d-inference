package estimate

import "github.com/eigeninference/d-inference/coordinator/internal/inference/jsonvalue"

// approximateTokenCount returns a rough token estimate for routing and queue
// admission. The len/4 heuristic is a reasonable average for English text
// with GPT-style BPE tokenizers. This value feeds into the scheduler's
// capacity checks (pendingTokenBudget, freeMemoryAdmits) where a tighter
// estimate produces better routing decisions.
//
// For billing reservation (where underestimation causes provider shortfall),
// use approximateTokenCountUpperBound instead.
func ApproximateTokenCount(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case string:
		return TextPromptTokens(x)
	default:
		n := jsonvalue.Len(v)
		if n == 0 {
			return 0
		}
		tokens := n / 4
		if tokens < 1 {
			tokens = 1
		}
		return tokens
	}
}

// textPromptTokens is the len/4 routing heuristic for one text string: empty
// text costs nothing, any other text at least one token.
func TextPromptTokens(s string) int {
	if s == "" {
		return 0
	}
	if t := len(s) / 4; t > 0 {
		return t
	}
	return 1
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
func ApproximateTokenCountUpperBound(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case string:
		return len(x)
	default:
		return jsonvalue.Len(v)
	}
}

// isMediaPartType reports whether an OpenAI/OpenRouter content-part type denotes
// image or video input.
func IsMediaPartType(t string) bool {
	switch t {
	// OpenAI chat (image_url/video_url), OpenAI Responses (input_image/input_video),
	// and Anthropic /v1/messages content blocks ({"type":"image"|"video","source":…}).
	case "image_url", "input_image", "image", "video_url", "input_video", "video":
		return true
	}
	return false
}
