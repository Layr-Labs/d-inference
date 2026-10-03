package api

// Smart early-429 admission (consumer request-path glue).
//
// This is the proactive half of the fix: before admitting/dispatching a public
// request, ask the registry whether the fleet could STRUCTURALLY serve a request
// of this size (prompt + max_tokens vs the model context window and the largest
// provider token-budget CEILING). When it confidently cannot, return an
// uptime-neutral 429 + Retry-After so OpenRouter fails over, instead of
// admitting it and letting the provider 5xx (the uptime-damaging
// "admitted_but_failed" path).
//
// Structural-only contract: this gate may 429 only requests that could NEVER
// fit — the budget comparison uses each provider's ceiling (resident
// active_token_budget_max / optimistic cold post-load estimate), never the live
// remaining budget. A request that fits some ceiling but not the fleet's
// current headroom is transient fullness and must fall through to the
// capacity/queue path (queue-before-shed in runInferenceAdmission), which holds
// it until a slot frees rather than shedding it.
//
// The gate is ON by default (see servabilityGateEnabled) and is fail-open by
// construction (PredictServable only rejects clearly-unservable requests). The
// always-on reclassification of an actual provider token-budget 5xx → 429 lives
// on the dispatch-exhausted path (see classifyInferenceFailure / dispatch.go).
