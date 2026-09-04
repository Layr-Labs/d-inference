package registry

import (
	"math"
	"strings"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Online completion-length calibration from usage.completion_tokens.
//
// The routing cost's per-request decode term (buildCandidateInto,
// scheduler.go) was max_tokens / effectiveTPS: the WORST-case completion on an
// IDLE box. ensureMaxTokensBound injects the model's max_output_length
// (32,768 for gpt-oss and gemma) whenever the client omitted max_tokens, so
// every such request ranked with a ~400-560 s decode term against a 3 s
// near-tie window and 3 s / 750 ms queue/pending penalties: a 1 tok/s TPS
// difference moved the cost by ~7 s and the selector degenerated into "fill
// the fastest box to its concurrency cap first" (top-10 provider share 36.7%
// at 32,768 vs 5.9% at <= 1K; gini 0.72 on a 70-box replay at 16K,
// dispatch_spread_test.go). Real completions are p50 ~200 / p90 ~1,000. This
// calibrator learns the per-model completion length ONLINE and gives the
// router the EXPECTED decode work instead.
//
// Scope — ranking only. Admission (freeMemoryAdmits, pendingTokenBudget,
// providerBudgetFits, PredictServable), the capacity probes, the balance hold,
// finish_reason and ITPM/OTPM keep the forwarded max_tokens bound: the
// provider's own ledger reserves prompt + max_tokens of the forwarded body,
// and a coordinator admission that mirrors anything smaller produces
// admit -> token_budget_exhausted 503s that arm budget_clamp / capacity
// cooldowns against healthy pairs.
//
// Design:
//
//   - Keying: per model. A sliding window of the most recent
//     completionCalibrationWindowSize usage.CompletionTokens values with cached
//     p50/p90 (nearest rank, recomputed on write).
//   - Estimate: clamp(p90 x completionCalibrationP90Margin,
//     completionCalibrationMinTokens, requestedMax). p90-with-margin so the
//     router plans for the long tail without charging the whole bound; never
//     above the client's own bound.
//   - Warm-up: below completionCalibrationWarmupObs observations the estimate
//     is requestedMax — today's behaviour.
//   - Kill switch: EIGENINFERENCE_COMPLETION_CALIBRATION=off restores the
//     pre-calibration cost byte-for-byte: expected() returns requestedMax and
//     the scheduler seam (thisReqDecodeTokens) falls back to the bound. It is
//     evaluated ONCE per request where the value is computed, never per
//     candidate inside the fleet scan. Learning continues while off.
//
// Value field of Registry with a LEAF mutex and a lazily-created map
// (quoteTracker idiom): safe for bare &Registry{} and never takes r.mu/p.mu.

const (
	completionCalibrationWindowSize = 200
	completionCalibrationWarmupObs  = 30
	completionCalibrationP90Margin  = 1.25
	completionCalibrationMinTokens  = 64
)

// completionCalibrationEnabled is the live-read kill switch:
// EIGENINFERENCE_COMPLETION_CALIBRATION=off (or false/0) disables the
// expected-completion cost term. Read once per request (expected()).
func completionCalibrationEnabled() bool {
	v := strings.TrimSpace(env.EnvOr(env.EnvPrefix+"_COMPLETION_CALIBRATION", "on"))
	return !strings.EqualFold(v, "off") && v != "false" && v != "0"
}

type completionWindow struct {
	window sampleWindow
	p50    float64
	p90    float64
}

type completionCalibrator struct {
	mu      sync.RWMutex
	windows map[string]*completionWindow
}

func (c *completionCalibrator) record(model string, tokens int) {
	if model == "" || tokens <= 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.windows == nil {
		c.windows = make(map[string]*completionWindow)
	}
	w := c.windows[model]
	if w == nil {
		w = &completionWindow{window: newSampleWindow(completionCalibrationWindowSize)}
		c.windows[model] = w
	}
	w.window.add(float64(tokens))
	sorted := w.window.sorted()
	w.p50 = percentileOfSorted(sorted, 0.5)
	w.p90 = percentileOfSorted(sorted, 0.9)
}

// learnedP90 returns the cached p90 and whether the model has cleared warm-up.
func (c *completionCalibrator) learnedP90(model string) (float64, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	w := c.windows[model]
	if w == nil || w.window.total < completionCalibrationWarmupObs {
		return 0, false
	}
	return w.p90, true
}

// percentiles returns the cached (p50, p90) and the observation count for
// model (all zero when never observed). Ops/test introspection.
func (c *completionCalibrator) percentiles(model string) (p50, p90 float64, observations int64) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	w := c.windows[model]
	if w == nil {
		return 0, 0, 0
	}
	return w.p50, w.p90, w.window.total
}

// expected is the learned decode-length estimate, bounded to
// [completionCalibrationMinTokens, requestedMax] (requestedMax <= 0 means no
// upper bound). learned=false — with expected == requestedMax — below warm-up
// or when the kill switch is off.
func (c *completionCalibrator) expected(model string, requestedMax int) (int, bool) {
	if !completionCalibrationEnabled() {
		return requestedMax, false
	}
	p90, ok := c.learnedP90(model)
	if !ok || p90 <= 0 || math.IsNaN(p90) || math.IsInf(p90, 0) {
		return requestedMax, false
	}
	expected := int(math.Ceil(p90 * completionCalibrationP90Margin))
	if expected < completionCalibrationMinTokens {
		expected = completionCalibrationMinTokens
	}
	if requestedMax > 0 && expected > requestedMax {
		expected = requestedMax
	}
	return expected, true
}

// RecordCompletionObservation feeds the calibrator one completed request's
// usage.completion_tokens. Non-positive counts are ignored. Callers must
// exclude truncated completions (consumer disconnect / cancel) and
// right-censored rows (CompletionTokens >= the forwarded bound): the former
// would pull p90 down, the router would pack harder, and more streams would
// be abandoned — the wrong feedback direction under load; the latter are the
// bound, not the completion. (Skipping right-censored rows biases p90 slightly
// DOWN for models whose real tail exceeds the bound; acceptable for a ranking
// term that is always re-clamped to the bound.)
func (r *Registry) RecordCompletionObservation(model string, completionTokens int) {
	r.completionCal.record(model, completionTokens)
}

// ExpectedCompletionTokens is the decode length the router should plan for:
// clamp(p90 x 1.25, 64, requestedMax) once the model has cleared warm-up and
// the kill switch is on; requestedMax otherwise (today's behaviour).
// requestedMax <= 0 disables the upper bound.
func (r *Registry) ExpectedCompletionTokens(model string, requestedMax int) int {
	expected, _ := r.ExpectedCompletionTokensLearned(model, requestedMax)
	return expected
}

// ExpectedCompletionTokensLearned is ExpectedCompletionTokens plus whether the
// value is a LEARNED estimate (true) or the requestedMax passthrough (false).
// Callers that need a different cold fallback than requestedMax (the consumer's
// routing default for a request that omitted max_tokens) key off the flag.
func (r *Registry) ExpectedCompletionTokensLearned(model string, requestedMax int) (int, bool) {
	return r.completionCal.expected(model, requestedMax)
}

// CompletionCalibrationPercentiles returns the cached (p50, p90) completion
// length and the observation count for model, independent of the kill switch.
// Exposed for ops introspection and tests.
func (r *Registry) CompletionCalibrationPercentiles(model string) (p50, p90 float64, observations int64) {
	return r.completionCal.percentiles(model)
}

// thisReqDecodeTokens is the token count for the decode half of the routing
// cost's thisReqMs and for the waiting-backlog term (buildCandidateInto):
// pr.ExpectedCompletionTokens when set and below the request's max bound
// (reqMax, already normalized by the caller); else reqMax. The decode RATE is
// deliberately left as the caller's effectiveTPS: charging a herd-projected
// per-request rate here would double-count contention that the fixed
// queue/pending penalties already price, and pushed load below the
// decode-quality floor in the dispatch replay. The kill switch is enforced
// where the value is computed (completionCalibrator.expected, once per
// request), never here: this runs once per candidate inside the fleet scan and
// must not read the environment ~1,300 times per reservation.
func thisReqDecodeTokens(pr *PendingRequest, reqMax int) int {
	if pr == nil {
		return reqMax
	}
	if pr.ExpectedCompletionTokens > 0 && pr.ExpectedCompletionTokens < reqMax {
		return pr.ExpectedCompletionTokens
	}
	return reqMax
}
