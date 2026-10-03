package api

// PR #548 review follow-up (Codex P2, dispatch.go ~1143): a jinja_* provider
// error arrives as a raw 500 — exactly the sickness shape the inference-error,
// node-health, and stable-identity breakers count — and the dispatch loop fed
// it to all three via noteDispatchProviderError BEFORE the E4 relabel in
// shouldStopFailover ran. A few malformed tool histories could therefore
// quarantine healthy providers/pairs. The dispatch funnel (noteProviderError)
// now withholds the provider for non-provider-fault reasons
// (isNonProviderFaultErrorReason: jinja_* + tool_noncompliance), while
// keeping the refund + held-chunk side effects and leaving every
// capacity-class rejection (which the capacity cooldown legitimately keys on)
// untouched.
