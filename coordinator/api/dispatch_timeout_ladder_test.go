package api

// Timeout-class ladder cap regression tests (2026-09-01 congestion collapse).
//
// A first-chunk TIMEOUT (slow provider, reason "first_chunk_timeout") used to
// retry across the fleet with a fresh full reservation scan per attempt —
// unbounded except by maxDispatchAttempts=64 and the request-absolute
// first-content clock. Wall time per request was bounded; CPU was not:
// retry-amplified inbound (~100 req/s of retryable 429 traffic) times
// per-request fleet scans (~1,260 providers each) saturated every coordinator
// CPU into a stable death loop (attempt-0 route p50 40ms → 4.6s, success
// ~40%, 429s delivered after 11s). maxFirstChunkTimeoutRetries caps the
// timeout-class ladder the same way maxCapacityClassRetries caps capacity
// failovers, exhausting into the existing synthetic-timeout → 429
// reclassification (classifyExhaustedStatus).
