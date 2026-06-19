package registry

import (
	"math"
	"time"
)

// warm_pool_target.go holds the pure, side-effect-free math behind the
// warm-pool controller's capacity target (Layer 3 in docs/architecture/routing-v2.md).
//
// The controller drives warm capacity from measured demand using Little's Law:
//
//	L = λ · E[S]                         (requests concurrently in the system)
//	target_warm = ceil( L / quality_concurrency ) + burst_buffer
//
// where quality_concurrency is the largest per-provider batch that still keeps
// every in-batch request decoding at or above a quality floor, derived from the
// same rate(B) = solo / (1 + k·B) batch-degradation model the scheduler uses in
// projectedPerRequestDecodeTPS (k = effectiveTPSLoadFactor).
//
// Everything here is pure so it can be unit-tested without a Registry, heartbeats,
// or wall-clock timing.

// warmTargetParams are the controller tunables (sourced from WarmPoolConfig).
type warmTargetParams struct {
	// DecodeFloorTPS is the per-request sustained-decode quality floor. When a
	// provider's batch grows past the point where each request would decode
	// slower than this, the warm pool treats the provider as full and prefers
	// to warm another one. <= 0 disables the quality constraint.
	DecodeFloorTPS float64
	// LoadFactorK is the decode batch-degradation coefficient (the scheduler's
	// effectiveTPSLoadFactor): rate(B) = solo / (1 + k·B).
	LoadFactorK float64
	// BurstBuffer is the spare warm providers added on top of the demand-derived
	// target to absorb arrival bursts within a control interval.
	BurstBuffer int
	// FallbackQualityConcurrency is the per-provider quality concurrency used
	// when the floor is disabled or rates/caps are unknown. Must be >= 1.
	FallbackQualityConcurrency int
	// AssumedPromptTokens / AssumedCompletionTokens size the representative
	// request used to estimate E[S] from the fleet's prefill/decode rates.
	AssumedPromptTokens     int
	AssumedCompletionTokens int
	// MinServiceTime / MaxServiceTime clamp the estimated E[S] so a degenerate
	// rate (near-zero or huge) cannot produce an absurd target.
	MinServiceTime time.Duration
	MaxServiceTime time.Duration
}

// warmTargetInputs are the per-model measured inputs for a single planning tick.
// They are assembled by the controller from the fleet snapshot (warm/cold
// counts, in-flight load, representative rates) and the pressure/queue state.
type warmTargetInputs struct {
	Warm            int // warm providers serving the model right now
	EligibleCold    int // cold providers that could be warmed this tick
	RunningRequests int // Σ NumRunning across warm providers (served, decoding)
	WaitingRequests int // Σ NumWaiting across warm providers (provider-queued)
	QueueDepth      int // coordinator-side queued requests for the model
	// SpillArrivalRate is the EWMA arrival rate (requests/sec) of demand the warm
	// pool failed to serve at quality this window — the capacity_reject, ttft_miss
	// and cold_dispatch signals, including the W3 preflight-fed near-misses. This
	// is the term that lets the controller "see" demand it is currently shedding.
	SpillArrivalRate float64
	SoloDecodeTPS    float64 // representative solo (batch=0) decode tok/s
	PrefillTPS       float64 // representative prefill tok/s
	MaxProviderConc  int     // representative per-provider concurrency cap (0 = unknown)
	// DemandPressure is true when any pressure signal crossed its threshold this
	// window. With no demand pressure the pool is left as-is (no growth).
	DemandPressure bool
}

// qualityConcurrency returns the largest batch B a provider can run while every
// in-batch request still decodes at >= floor tok/s, under rate(B) = solo/(1+k·B):
//
//	solo / (1 + k·B) >= floor   <=>   B <= (solo/floor - 1) / k
//
// The result is clamped to [1, limit] where limit is the provider-reported
// concurrency cap (falling back to fallbackConc). When the floor is disabled
// (<= 0), the solo rate is unknown, or load scaling is off, the constraint does
// not bind and the cap is returned.
func qualityConcurrency(soloDecodeTPS, floor, k float64, maxProviderConc, fallbackConc int) int {
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

// estimateServiceTime estimates E[S] for a representative request: prefill of the
// assumed prompt plus decode of the assumed completion, using the representative
// fleet rates. Clamped to [MinServiceTime, MaxServiceTime].
func estimateServiceTime(prefillTPS, decodeTPS float64, p warmTargetParams) time.Duration {
	secs := 0.0
	if prefillTPS > 0 && p.AssumedPromptTokens > 0 {
		secs += float64(p.AssumedPromptTokens) / prefillTPS
	}
	if decodeTPS > 0 && p.AssumedCompletionTokens > 0 {
		secs += float64(p.AssumedCompletionTokens) / decodeTPS
	}
	d := time.Duration(secs * float64(time.Second))
	if p.MinServiceTime > 0 && d < p.MinServiceTime {
		d = p.MinServiceTime
	}
	if p.MaxServiceTime > 0 && d > p.MaxServiceTime {
		d = p.MaxServiceTime
	}
	return d
}

// demandConcurrency is L = λ·E[S] in Little's Law: the number of concurrent
// requests the warm pool must host to serve current demand at quality. It is the
// observed in-system load (decoding + provider-queued + coordinator-queued) PLUS
// the spilled arrival stream the pool failed to serve, converted to a concurrency
// by Little's Law (λ_spill · E[S]). Folding the gauge and the spill together is
// what fixes the prod failure where a pool pinned at capacity hid the true
// demand behind a wall of 429s.
func demandConcurrency(in warmTargetInputs, svc time.Duration) float64 {
	served := float64(in.RunningRequests + in.WaitingRequests + in.QueueDepth)
	spill := in.SpillArrivalRate * svc.Seconds()
	if spill < 0 {
		spill = 0
	}
	return served + spill
}

// warmTarget computes the Little's Law warm-provider target for one model:
//
//	target = ceil( demandConcurrency / qualityConcurrency ) + burstBuffer
//
// A single unmet pressure event always justifies at least one more warm provider
// (the reactive floor), so the controller still nudges forward while the smoothed
// arrival rate is small. The result never shrinks below the current warm count
// within a tick (dwell is enforced by the caller) and never exceeds what the
// fleet can actually warm (warm + eligibleCold). With no demand pressure the pool
// is left as-is.
func warmTarget(in warmTargetInputs, p warmTargetParams, svc time.Duration) int {
	if !in.DemandPressure {
		return in.Warm
	}
	qc := qualityConcurrency(in.SoloDecodeTPS, p.DecodeFloorTPS, p.LoadFactorK, in.MaxProviderConc, p.FallbackQualityConcurrency)
	if qc < 1 {
		qc = 1
	}
	L := demandConcurrency(in, svc)
	target := int(math.Ceil(L/float64(qc))) + p.BurstBuffer
	if reactive := in.Warm + 1; reactive > target {
		target = reactive
	}
	if target < in.Warm {
		target = in.Warm
	}
	if maxReachable := in.Warm + in.EligibleCold; target > maxReachable {
		target = maxReachable
	}
	if target < 0 {
		target = 0
	}
	return target
}

// rampLoadsThisTick returns the demand-scaled, bounded number of model loads to
// issue this tick to close `gap` (= target - warm). The per-tick burst scales
// with the gap (gapFraction of it) but is floored at `base` and hard-capped at
// `ceiling`, so a large demand spike ramps quickly without unbounded thundering.
// gapFraction <= 0 falls back to the flat `base` burst.
func rampLoadsThisTick(gap, base, ceiling int, gapFraction float64) int {
	if gap <= 0 {
		return 0
	}
	if base < 1 {
		base = 1
	}
	if ceiling < base {
		ceiling = base
	}
	loads := base
	if gapFraction > 0 {
		if scaled := int(math.Ceil(float64(gap) * gapFraction)); scaled > loads {
			loads = scaled
		}
	}
	if loads > ceiling {
		loads = ceiling
	}
	if loads > gap {
		loads = gap
	}
	return loads
}

// medianFloat returns the median of the samples, or 0 for an empty slice. Used to
// pick a representative fleet rate without letting one outlier dominate. It sorts
// a copy so callers keep their slice order.
func medianFloat(samples []float64) float64 {
	n := len(samples)
	if n == 0 {
		return 0
	}
	cp := make([]float64, n)
	copy(cp, samples)
	sortFloat64s(cp)
	mid := n / 2
	if n%2 == 1 {
		return cp[mid]
	}
	return (cp[mid-1] + cp[mid]) / 2
}

// sortFloat64s is a tiny insertion sort kept local to avoid pulling sort.Float64s
// (and its interface allocs) into the hot snapshot path for the small per-model
// rate-sample slices.
func sortFloat64s(a []float64) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j-1] > a[j]; j-- {
			a[j-1], a[j] = a[j], a[j-1]
		}
	}
}
