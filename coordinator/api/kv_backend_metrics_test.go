package api

// Gate G5 (v0.8.0 paged rollout): the coordinator must be able to segment
// TTFT / decode-TPS / error-rate by KV backend. These tests drive the REAL
// emission paths against a REAL DogStatsD client over a local UDP collector,
// so deleting a tag or an emit fails here rather than silently producing an
// un-segmentable dashboard.
//
// The load-bearing property throughout: a pre-0.8.0 provider that omits
// kv_backend must land in its OWN population, never fold into contiguous.
