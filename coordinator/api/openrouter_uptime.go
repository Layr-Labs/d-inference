package api

// OpenRouter-formula uptime instrumentation.
//
// OpenRouter scores a provider by uptime = successful / total, where the
// denominator EXCLUDES 429 (rate-limit), 400, 413, 403, and COUNTS as failure
// all 5xx, mid-stream errors, and fetch-timeouts. The number we are actually
// graded on therefore is:
//
//	uptime = success / (success + provider_5xx + mid_stream + timeout)
//
// To watch that number live we emit ONE counter, d_inference.inference.request_outcome,
// tagged {model, class, kv_backend}, exactly once per client request, at the two
// disjoint request-terminal chokepoints:
//
//   - dispatch.go run() tail — every DISPATCHED request emits exactly once:
//     committed → success (the consumer got content), exhausted → the failure
//     class derived from the final HTTP status (after the token-budget→429
//     reclassification).
//   - recordRejection (rejection_telemetry.go) — every PRE-dispatch rejection
//     (stage != "dispatch") emits exactly once from its HTTP status. The
//     dispatch-stage exhausted rejection is skipped there because run()'s tail
//     already counted it.
//
// These two sets are disjoint (a request is either dispatched or rejected before
// dispatch), so there is no double counting and no per-attempt / speculative
// inflation. A committed request that later fails mid-stream is counted as success
// (commit-time approximation); the exact post-commit breakdown is available from
// the persisted route-outcome rows (GET /v1/admin/routes, filter by final_status)
// and the rejection ledger (GET /v1/admin/rejections).
//
// Scope: dispatched-request outcomes are emitted on the /v1/chat/completions
// (+ Responses) path, which is what OpenRouter scores us on. The inline
// /v1/completions + /v1/messages path emits only its pre-dispatch rejections
// (via recordRejection); its dispatched successes/failures are not counted here.
// The classes rate_limited / client_error are tracked but EXCLUDED from the
// formula above, matching OpenRouter's denominator.
