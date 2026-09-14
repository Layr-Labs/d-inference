package throughput

import "math"

const (
	// LoadFactor controls how aggressively decode TPS
	// degrades as a provider takes on more concurrent requests. The
	// effective TPS used in cost is `decodeTPS / (1 + k * batchSize)`
	// where batchSize is the backend's currently-running request count.
	//
	// Measured on M4 Max against the CBv2 engine and a model this
	// coordinator actually serves — gemma-4-26b-qat-4bit, per-request
	// decode at B = 1/2/4/8 = 101.8 / 59.6 / 38.0 / 24.7 (v2 rows of
	// libs/mlx-swift-lm/benchmarks/reports/gemma4-26b-qat4bit-paged-gate-2026-07-09.md).
	// Method: median of the implied k over B = 2/4/8, solo pinned to the
	// B=1 measurement — 0.354 / 0.420 / 0.390 -> 0.39. A least-squares fit
	// of 1/rate against B agrees (0.3895). The SAME method reproduces the
	// previous 0.27 exactly from the legacy rows (Qwen2.5-7B-4bit on the
	// legacy engine: 92.8 / 69.5 / 35.9 / 29.6 -> 0.2669), so this is a
	// change of engine and model, not of method. Cross-checks: gemma
	// v2-paged 0.388, v2-compiled 0.419; gpt-oss-20b v2-eager 0.432,
	// v2-paged 0.325.
	//
	// 0.27 errs in the LENIENT direction against CBv2 — it UNDER-predicts
	// degradation, i.e. over-predicts the surviving rate, and the error
	// grows with batch:
	//
	//	B    measured    k=0.27 pred       k=0.39 pred
	//	2    59.6        66.1   (+10.9%)   57.2   (-4.1%)
	//	4    38.0        48.9   (+28.8%)   39.8   (+4.6%)
	//	8    24.7        32.2   (+30.4%)   24.7   (-0.0%)
	//	                 MAPE 23.4%        MAPE 2.9%
	//
	// B=1 is the model's INPUT (solo), not a prediction, so it is not
	// scored. Mind the SIGN: 0.27 is too SMALL, not too large. A reading
	// that it was wildly "too aggressive" comes from comparing a
	// prediction made with the coordinator's sqrt(memory_bandwidth) proxy
	// solo (16-28 tok/s) against a rate measured at the engine's real solo
	// (101.8) — that gap is a bad SOLO rate, not a bad k, and it has its
	// own lever (modelSoloTPSSeedEnv in concurrency_cap.go). Raising k
	// makes every derived cap TIGHTER, never looser.
	//
	// Four systems consume this and a too-small k over-states the quality
	// batch in all of them at once: the admission cap (concurrency_cap.go),
	// effectiveDecodeTPS and projectedPerRequestDecodeTPSAtBatch below, and
	// the warm-pool target (warm_pool_controller.go) — which then
	// under-warms the pool while admission packs batches that miss the
	// decode floor.
	// Set to 0 to disable load scaling.
	LoadFactor = 0.39
)

// QualityConcurrency returns the largest batch B a provider can run while every
// in-batch request still decodes at >= floor tok/s, under rate(B) = solo/(1+k·B):
//
//	solo / (1 + k·B) >= floor   <=>   B <= (solo/floor - 1) / k
//
// The result is clamped to [1, limit] where limit is the provider-reported
// concurrency cap (falling back to fallbackConc). When the floor is disabled
// (<= 0), the solo rate is unknown, or load scaling is off, the constraint does
// not bind and the cap is returned.
//
// k is MEASURED per engine generation, not chosen, and this function is the
// most load-bearing consumer of getting it wrong in the safe-looking
// direction: too SMALL a k over-states the quality batch, which divides
// Little's Law demand by too much and under-warms the pool — a shortfall that
// reads as demand undershoot rather than as a stale coefficient.
func QualityConcurrency(soloDecodeTPS, floor, k float64, maxProviderConc, fallbackConc int) int {
	limit := maxProviderConc
	if limit <= 0 {
		limit = fallbackConc
	}
	if limit < 1 {
		limit = 1
	}
	if floor <= 0 || soloDecodeTPS <= 0 || k <= 0 {
		return limit
	}
	if soloDecodeTPS <= floor {
		// Even a solo request is at or below the floor: one request per provider
		// is the most we can run without violating quality.
		return 1
	}
	b := int(math.Floor((soloDecodeTPS/floor - 1) / k))
	if b < 1 {
		b = 1
	}
	if b > limit {
		b = limit
	}
	return b
}
