package providerwire

import inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"

// EnsureMaxTokensBound injects a catalog/default output bound when none was
// supplied, and mirrors chat alias fields into the provider's max_tokens field.
// It reports whether the provider body needs serialization.
func EnsureMaxTokensBound(parsed map[string]any, isResponsesAPI bool, bound int) bool {
	n := 0
	for _, key := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		if value, ok := inreq.IntFromRequestValue(parsed[key]); ok && value > 0 {
			n = value
			break
		}
	}
	if n > 0 {
		if !isResponsesAPI {
			if cur, ok := inreq.IntFromRequestValue(parsed["max_tokens"]); !ok || cur <= 0 {
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
