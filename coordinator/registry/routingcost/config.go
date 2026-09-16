package routingcost

import (
	"math"
)

// Policy.LongPromptPenalty returns the EXTRA first-token-blocking cost (ms) added to a
// candidate's per-request cost so very long prompts prefer the provider that
// reaches first token soonest. It amplifies the supplied time-to-first-token
// (ttftBlockMs) by (weight-1). The caller passes the FULL TTFT: prefill for a warm
// provider, or model-load latency + prefill for a cold one. Amplifying the full
// TTFT (rather than prefill alone) means a cold box's fast prefill cannot win a
// long prompt when its ~30s load makes it slower end-to-end than the fastest warm
// provider, while a warm provider with twice the prefill throughput still sees
// half the penalty so the fastest chip-tier wins decisively.
//
// Returns 0 (fully behavior-preserving) when the preference is disabled
// (threshold <= 0), the prompt is below the threshold (short prompts unaffected),
// the weight is neutral (<= 1), or the blocking time is non-positive. It is a SOFT
// ranking bias only: no candidate is dropped and no TTFT 429 is introduced.
func (policy *Policy[Connection]) LongPromptPenalty(reqPromptTokens int, ttftBlockMs float64) float64 {
	if policy.longPromptThresholdTokens <= 0 || reqPromptTokens < policy.longPromptThresholdTokens {
		return 0
	}
	if ttftBlockMs <= 0 || policy.longPromptPrefillWeight <= 1.0 {
		return 0
	}
	return (policy.longPromptPrefillWeight - 1.0) * ttftBlockMs
}

// Policy.SetPrefillToDecodeRatio overrides the decode→prefill fallback multiplier.
// Values <= 0 are ignored. Must be called before serving starts (read-only after).
func (policy *Policy[Connection]) SetPrefillToDecodeRatio(ratio float64) {
	if ratio > 0 {
		policy.prefillToDecodeRatio = ratio
	}
}

// Policy.PrefillToDecodeRatio returns the current decode→prefill fallback multiplier
// (the value used by resolvedPrefillTPS when a provider does not report a
// measured prefill rate). Exposed for the routing simulation harness.
func (policy *Policy[Connection]) PrefillToDecodeRatio() float64 {
	return policy.prefillToDecodeRatio
}

// Policy.SetTTFTOccupancyAlpha overrides the occupancy-term coefficient. Negative
// values are clamped to 0 (term disabled). Must be called before serving starts.
func (policy *Policy[Connection]) SetTTFTOccupancyAlpha(alpha float64) {
	if alpha < 0 {
		alpha = 0
	}
	policy.ttftOccupancyAlpha = alpha
}

// Policy.TTFTOccupancyAlpha returns the configured occupancy-term coefficient.
func (policy *Policy[Connection]) TTFTOccupancyAlpha() float64 {
	return policy.ttftOccupancyAlpha
}

// Policy.SetLongPromptThreshold sets the estimated-prompt-token count at/above which the
// long-prompt fastest-tier routing preference activates. A value <= 0 disables the
// preference (behavior-neutral). Must be called before serving starts.
func (policy *Policy[Connection]) SetLongPromptThreshold(tokens int) {
	if tokens < 0 {
		tokens = 0
	}
	policy.longPromptThresholdTokens = tokens
}

// Policy.LongPromptThreshold returns the current long-prompt token threshold (0 = off).
func (policy *Policy[Connection]) LongPromptThreshold() int {
	return policy.longPromptThresholdTokens
}

// Policy.SetLongPromptPrefillWeight overrides the prefill-term multiplier used for long
// prompts. Non-finite values (NaN/±Inf — which slip through a naive `< 1` clamp
// because NaN comparisons are always false, then poison every candidate cost) are
// reset to the default. Values < 1 are clamped to 1.0 (no amplification). Must be
// called before serving starts.
func (policy *Policy[Connection]) SetLongPromptPrefillWeight(w float64) {
	weight := w
	if math.IsNaN(weight) || math.IsInf(weight, 0) {
		weight = DefaultLongPromptPrefillWeight
	}
	if weight < 1.0 {
		weight = 1.0
	}
	policy.longPromptPrefillWeight = weight
}

// Policy.LongPromptPrefillWeight returns the current long-prompt prefill-term multiplier.
func (policy *Policy[Connection]) LongPromptPrefillWeight() float64 {
	return policy.longPromptPrefillWeight
}

// DefaultPrefillToDecodeRatio is the fallback multiplier applied to a provider's
// decode TPS to estimate its prefill TPS when the provider does not report a
// measured prefill rate (prefill_tps). Apple-Silicon MLX prefills the prompt in
// large parallel batches, so prefill throughput is roughly an order of magnitude
// above decode throughput. The historical 4x was far too conservative: combined
// with the 5s+1ms/token TTFT deadline it estimated ~100 tok/s prefill (vs the
// ~1000 tok/s the deadline implicitly assumes), so the TTFT gate wrongly
// rejected warm, capable providers on any prompt above ~550 tokens. No provider
// currently reports prefill_tps, so this fallback is the production path.
const DefaultPrefillToDecodeRatio = 12.0

// DefaultLongPromptThresholdTokens gates the long-prompt fastest-tier routing
// preference. 0 disables it entirely (behavior-neutral): the routing
// cost is unchanged for every request, short or long. A positive value turns the
// preference ON for requests whose estimated prompt is at or above the threshold.
const DefaultLongPromptThresholdTokens = 0

// DefaultLongPromptPrefillWeight is the multiplier applied to the prefill term of
// the routing cost for long prompts. 1.0 is behavior-neutral; >1 amplifies the
// prefill component so the fastest-prefill (== fastest chip tier) warm provider is
// strongly preferred once the prompt is long enough that prefill dominates TTFT.
const DefaultLongPromptPrefillWeight = 2.0
