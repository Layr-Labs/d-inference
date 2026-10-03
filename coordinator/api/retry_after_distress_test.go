package api

// estimateRetryAfter distress-scaling tests (2026-09-01 congestion collapse).
//
// Queue depth alone was a liar under CPU saturation: the queue was empty
// (nothing could reach it), so every 429 carried "Retry-After: 2" and
// upstream retried every 2s, sustaining the death loop. When the attempt-0
// route-latency EWMA shows routing itself is degraded (> 1s), the answer
// must scale with the observed degradation — max(base, ceil(EWMA_s)*5),
// capped at 60 — while healthy routing keeps the legacy queue-depth values.
