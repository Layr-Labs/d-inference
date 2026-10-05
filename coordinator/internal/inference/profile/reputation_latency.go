package profile

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// writeCommittedResponse writes the provider attestation + timing headers, installs
// the park-before-remove settlement defer, and hands off to the streaming /
// non-streaming response writer. Extracted verbatim from the committed tail of the
// original handler.
// contentLatency is the time from dispatch to the first CONTENT chunk delivered
// to the client (FirstContentAt). It deliberately does NOT fall back to
// FirstChunkAt — that timestamp is also stamped on held role-only / lifecycle
// preamble, so using it would let a fast-preamble-then-stall provider (or a
// preamble-only clean close that produced no content) look artificially
// responsive. Returns 0 when no content was delivered or the timing is
// incomplete, which the caller treats as "no sample".
func ContentLatency(t *registry.RequestTiming) time.Duration {
	if t == nil || t.DispatchedAt.IsZero() || t.FirstContentAt.IsZero() {
		return 0
	}
	if d := t.FirstContentAt.Sub(t.DispatchedAt); d > 0 {
		return d
	}
	return 0
}

// adjustLatencyForPrefill turns a raw time-to-first-content into the reputation
// latency sample by removing the prompt-size-dependent prefill. Time-to-first-
// token grows with the input length, so a provider serving long prompts would
// otherwise look slow purely because of its workload. Using the provider's own
// benchmarked prefill rate keeps the correction per-provider and free of
// hard-coded constants; what remains approximates queueing, scheduling,
// model-load and first-decode overhead. Returns 0 when there is no usable sample
// (which RecordLatency ignores), including when the prefill estimate exceeds the
// measured latency.
func AdjustLatencyForPrefill(raw time.Duration, promptTokens int, prefillTPS float64) time.Duration {
	if raw <= 0 {
		return 0
	}
	if promptTokens > 0 && prefillTPS > 0 {
		raw -= time.Duration(float64(promptTokens) / prefillTPS * float64(time.Second))
	}
	if raw <= 0 {
		return 0
	}
	return raw
}

func ShouldRecordReputationLatency(pr *registry.PendingRequest, firstChunk string) bool {
	return pr != nil && pr.Timing != nil && firstChunk != "" && !pr.CacheRoutingParticipates()
}
