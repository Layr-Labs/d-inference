package api

// Client-gone (cancellation) telemetry helpers.
//
// Long-prompt gpt-oss requests are admitted and served under the soft TTFT gate,
// but their long prefill makes clients time out and disconnect before the first
// content token. Those disconnects are recorded as cancelled / client_gone. To
// quantify the problem we emit a DogStatsD counter (d_inference.routing.client_gone)
// tagged by model, estimated-prompt-token bucket, provider chip family, and the
// lifecycle PHASE at which the client went away (before the first content token vs
// after the response committed). This file owns the small, pure bucket helper plus
// the thin emit wrapper so the call sites stay one-liners.

// providerChipFamily reads a provider's hardware chip family under its lock,
// returning "" for a nil provider. Best-effort: the value feeds a metric tag only.
