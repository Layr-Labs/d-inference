package ingress

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
