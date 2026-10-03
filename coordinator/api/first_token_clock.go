package api

// The request-absolute first-token clock.
//
// OpenRouter (and OpenRouter-shaped aggregators) cancel a request when no REAL
// completion token has arrived within ~10000ms + 1ms x prompt_tokens measured
// from the moment THEY sent the request. The coordinator writes no HTTP response
// bytes before first content; a provider `inference_accepted` ack is internal
// liveness and does not satisfy the aggregator's rule.
// Production evidence (2026-08-15): ~11k/day client_gone rows fit that line
// within ±250ms while the coordinator was still waiting on a 600s post-accept
// budget.
//
// Everything here derives from one clock:
// ReceivedAt + Server.FirstContentDeadline(model, tokens). Ordinary production
// selected accounts use 9s + 1ms/token inside the aggregator's standard 10s slope;
// exact model policies may tighten both clocks while preserving response
// headroom (Qwen3-VL Instruct: 4s live inside a 5s upstream SLA).
// Accounts outside FIRST_CONTENT_SLA_ACCOUNTS carry a zero duration: no
// first-content timer, scheduler ceiling, or provider wire budget. Provider
// write watchdogs, queue limits and client cancellation remain. Response/stream
// timeouts begin only after first content has committed.
// Invariants:
//
//  1. With an SLA, no first-CONTENT wait extends past the leftover clock — not
//     accept, not preamble liveness, not a speculative race extension.
//  2. Expiry of OUR clock is not provider sickness. Per-provider fault
//     breakers may only be fed when the provider was actually granted a
//     provider-attributable window (providerAttributableStall).
//  3. The clock bounds blocking provider writes too (firstTokenWriteContext):
//     a congested write lane must not eat the budget invisibly.
//  4. A token that entered before the deadline beats the timer even when it is
//     still buffered; ingress after the deadline never commits. Deadline arms
//     drain ChunkCh because a zero-duration timer and ready chunk race in select.
//  5. When ReceivedAt was never stamped (unit tests), every helper falls back
//     to the historical relative timers.
