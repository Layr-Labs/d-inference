package metrics

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

// promptBucket maps an estimated prompt-token count to a coarse, fixed-cardinality
// bucket label for metrics. Boundaries: <1k, 1-4k, 4-8k, 8-16k, 16k+. Negative or
// zero counts fall into the smallest bucket. The buckets are deliberately coarse so
// the metric stays low-cardinality and the estimate's imprecision (it is a routing
// heuristic, not a tokenizer-exact count) never straddles a boundary in practice.
func PromptBucket(tokens int) string {
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

// emitClientGone records a client cancellation on the DogStatsD counter
// d_inference.routing.client_gone, tagged by model, prompt-token bucket, provider
// chip family, and lifecycle phase. It is a no-op when Datadog is not configured
// (ddIncr guards nil). chipFamily is normalized to "unknown" when empty (e.g. the
// request was cancelled in the queue before a provider was chosen) so the tag is
// always present for dashboard grouping.
func (s *Reporter) ClientGone(model string, promptTokens int, chipFamily, phase string) {
	// After-commit callers (provider terminals, settlement grace) have no
	// first-content clock to bucket against: the budget was met before commit.
	s.ClientGoneBucketed(model, promptTokens, chipFamily, phase, deadlineNotApplicable)
}

// emitClientGoneBucketed is emitClientGone with the deadline_bucket tag: for a
// pre-content cancel, how far into the first-content budget the client left
// (see deadlineBucket), which separates "the upstream timed out on us" from an
// early application abort. deadlineBucket is normalized to "unknown" when empty.
func (s *Reporter) ClientGoneBucketed(model string, promptTokens int, chipFamily, phase, deadlineBucket string) {
	chipFamily = observation.SanitizeChipFamilyTag(chipFamily)
	if deadlineBucket == "" {
		deadlineBucket = deadlineUnknown
	}
	s.Observation.Incr("routing.client_gone", []string{
		"model:" + model,
		"prompt_bucket:" + PromptBucket(promptTokens),
		"chip_family:" + chipFamily,
		"phase:" + phase,
		"deadline_bucket:" + deadlineBucket,
	})
}
