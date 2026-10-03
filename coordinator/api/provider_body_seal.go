package api

// provider_body_seal.go seals a provider body for a protocol-0 cache
// isolation attempt (the per-attempt prompt_cache_key buster) and sizes the
// result without necessarily building it. Both take the splice fast path of
// provider_body_splice.go for bodies proven canonical and fall back to the
// decode/re-encode path otherwise; bodyForCacheAttempt (consumer.go) is the
// dispatch-time caller, the sizing probes behind routingTraitsForProviderBody
// are the pre-dispatch ones.
