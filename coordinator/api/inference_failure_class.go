package api

import "strings"

// isUnservableProviderError reports whether a provider inference-error message
// indicates the request was ADMITTED but then rejected because it could not fit
// the provider — (prompt + max_tokens) overflowed its token budget / KV-cache
// headroom / context window, or the model OOM'd at load. These are CAPACITY-class
// conditions, not genuine server faults.
//
// When the dispatch path exhausts all attempts with such an error, the
// coordinator reclassifies the provider's raw 5xx to an uptime-NEUTRAL 429.
// OpenRouter treats 429 as rate-limiting (no uptime penalty) and fails over,
// whereas the 5xx counts against our uptime — and these "admitted_but_failed"
// long-prompt 5xx were the dominant gpt-oss uptime regression. This is the
// always-on backstop that complements the (gated) proactive servability gate:
// it fires only on an ACTUAL provider rejection, so it carries no
// over-rejection risk.
//
// Matching is substring/case-insensitive because the strings are human-readable
// and drift across provider versions. It mirrors the provider's scheduler reject
// strings ("token_budget_exhausted: …", "insufficient global kv cache headroom",
// "… exceeds batch token budget") and the load-time memory strings already
// classified by classifyLoadFailure.
func isUnservableProviderError(errStr string) bool {
	s := strings.ToLower(strings.TrimSpace(errStr))
	if s == "" {
		return false
	}
	switch {
	case strings.Contains(s, "token_budget_exhausted"),
		strings.Contains(s, "token budget"),
		strings.Contains(s, "kv cache headroom"),
		strings.Contains(s, "kv headroom"),
		strings.Contains(s, "insufficient kv"),
		strings.Contains(s, "insufficient memory"),
		strings.Contains(s, "out of memory"),
		containsWord(s, "oom"),
		strings.Contains(s, "context length"),
		strings.Contains(s, "context window"),
		strings.Contains(s, "exceeds") && strings.Contains(s, "context"):
		return true
	default:
		return false
	}
}
