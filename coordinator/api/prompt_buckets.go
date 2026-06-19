package api

import "github.com/eigeninference/d-inference/coordinator/registry"

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

// client_gone phase tags. before_first_token is the prefill window (the request
// was cancelled before any content token committed); after_commit is a disconnect
// once streaming had already started (provider completed/errored with no reader).
const (
	phaseBeforeFirstToken = "before_first_token"
	phaseAfterCommit      = "after_commit"
)

// promptBucket maps an estimated prompt-token count to a coarse, fixed-cardinality
// bucket label for metrics. Boundaries: <1k, 1-4k, 4-8k, 8-16k, 16k+. Negative or
// zero counts fall into the smallest bucket. The buckets are deliberately coarse so
// the metric stays low-cardinality and the estimate's imprecision (it is a routing
// heuristic, not a tokenizer-exact count) never straddles a boundary in practice.
func promptBucket(tokens int) string {
	switch {
	case tokens < 1_000:
		return "<1k"
	case tokens < 4_000:
		return "1-4k"
	case tokens < 8_000:
		return "4-8k"
	case tokens < 16_000:
		return "8-16k"
	default:
		return "16k+"
	}
}

// providerChipFamily reads a provider's hardware chip family under its lock,
// returning "" for a nil provider. Best-effort: the value feeds a metric tag only.
func providerChipFamily(p *registry.Provider) string {
	if p == nil {
		return ""
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.Hardware.ChipFamily
}

// emitClientGone records a client cancellation on the DogStatsD counter
// d_inference.routing.client_gone, tagged by model, prompt-token bucket, provider
// chip family, and lifecycle phase. It is a no-op when Datadog is not configured
// (ddIncr guards nil). chipFamily is normalized to "unknown" when empty (e.g. the
// request was cancelled in the queue before a provider was chosen) so the tag is
// always present for dashboard grouping.
func (s *Server) emitClientGone(model string, promptTokens int, chipFamily, phase string) {
	if chipFamily == "" {
		chipFamily = "unknown"
	}
	s.ddIncr("routing.client_gone", []string{
		"model:" + model,
		"prompt_bucket:" + promptBucket(promptTokens),
		"chip_family:" + chipFamily,
		"phase:" + phase,
	})
}
