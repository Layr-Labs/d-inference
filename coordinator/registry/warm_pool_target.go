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
	// HeadroomProviders is a per-model OVERRIDE of the derived proactive floor
	// (EIGENINFERENCE_WARM_POOL_HEADROOM_PROVIDERS, "model=N,..."). Normally the
	// floor is DERIVED per model from measured demand growth — see
	// warmTargetInputs.OccupancyRamp and headroomTarget — because the right value
	// is a property of a model's own traffic shape and cold-load time, not
	// something an operator can guess: measured across the live fleet it ranges
	// from 2 to 33 providers across the six served builds, and the same constant
	// is simultaneously a rounding error on a 374-warm pool and an 8x expansion
	// on a 1-warm one. An entry here pins a model, for a build whose measured
	// ramp is not yet trustworthy (e.g. freshly launched, no samples).
	HeadroomProviders map[string]int
	// HeadroomEnabledParams turns the proactive floor on. False restores the
	// purely reactive pre-2026-09 behaviour, where the pool could only grow after
	// a request had already been shed or delayed.
	HeadroomEnabledParams bool
	// HeadroomMaxProviders caps any single model's derived floor so a pathological
	// ramp measurement cannot demand the entire fleet. <= 0 means uncapped.
	HeadroomMaxProviders int
	// HeadroomLoadWindows scales the derived floor: headroom covers the demand
	// growth expected over this many control intervals, approximating how long a
	// cold provider takes to become servable. 0 falls back to 1.
	HeadroomLoadWindows float64
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
	// Model is the concrete build id, used to resolve a per-model headroom
	// override. Empty means no override can match, so the derived floor applies.
	Model string
	Warm  int // warm providers serving the model right now
	// WarmSaturated is the subset of Warm with NO concurrency headroom left
	// (measured in warmPoolFleetSnapshot). Warm counts weights-resident
	// providers including those actively serving, so this is what separates
	// "resident" from "able to accept work": available = Warm - WarmSaturated.
	WarmSaturated   int
	EligibleCold    int // cold providers that could be warmed this tick
	RunningRequests int // Σ NumRunning across warm providers (served, decoding)
	WaitingRequests int // Σ NumWaiting across warm providers (provider-queued)
	QueueDepth      int // coordinator-side queued requests for the model
	// SpillArrivalRate is the EWMA arrival rate (requests/sec) of demand the warm
	// pool failed to serve at quality this window — the capacity_reject, ttft_miss
	// and cold_dispatch signals, including the W3 preflight-fed near-misses. This
	// is the term that lets the controller "see" demand it is currently shedding.
	SpillArrivalRate float64
	// OccupancyRamp is the measured per-interval RISE in occupied slots for this
	// model (EWMA, increases only). It is the demand-GROWTH rate the derived
	// proactive headroom floor is sized from — distinct from SpillArrivalRate,
	// which counts only demand the pool already failed to serve.
	OccupancyRamp   float64
	SoloDecodeTPS   float64 // representative solo (batch=0) decode tok/s
	PrefillTPS      float64 // representative prefill tok/s
	MaxProviderConc int     // representative per-provider concurrency cap (0 = unknown)
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
//
// k is MEASURED per engine generation, not chosen, and this function is the
// most load-bearing consumer of getting it wrong in the safe-looking
// direction: too SMALL a k over-states the quality batch, which divides
// Little's Law demand by too much and under-warms the pool — a shortfall that
// reads as demand undershoot rather than as a stale coefficient.
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
// and then applies a PROACTIVE HEADROOM FLOOR (see headroomTarget) so the pool
// keeps spare *serving capacity* ahead of demand instead of only reacting to
// requests that already failed.
//
// A single unmet pressure event always justifies at least one more warm provider
// (the reactive floor), so the controller still nudges forward while the smoothed
// arrival rate is small. The result never shrinks below the current warm count
// within a tick (dwell is enforced by the caller) and never exceeds what the
// fleet can actually warm (warm + eligibleCold).
//
// Growth is NOT gated on demand pressure. It used to be: with no pressure signal
// the function returned in.Warm unchanged, so the ONLY way the pool could grow
// was a capacity_reject / ttft_miss / cold_dispatch — i.e. a request that had
// already been shed or delayed. Combined with the reactive floor (warm+1) that
// made growth +1 provider per control interval (30s in prod) no matter how large
// the shortfall, so the pool was smallest exactly when load was rising. The
// headroom floor below replaces that with anticipatory growth; the pressure
// signals still accelerate it through demandConcurrency's spill term.
func warmTarget(in warmTargetInputs, p warmTargetParams, svc time.Duration) int {
	qc := qualityConcurrency(in.SoloDecodeTPS, p.DecodeFloorTPS, p.LoadFactorK, in.MaxProviderConc, p.FallbackQualityConcurrency)
	if qc < 1 {
		qc = 1
	}
	L := demandConcurrency(in, svc)
	target := int(math.Ceil(L/float64(qc))) + p.BurstBuffer
	// Proactive headroom: hold spare serving capacity above current load even
	// when nothing has failed yet.
	if hd := headroomTarget(in, p, qc); hd > target {
		target = hd
	}
	// Reactive nudge: an unmet pressure event always justifies one more provider,
	// even if the smoothed terms above have not caught up yet.
	if in.DemandPressure {
		if reactive := in.Warm + 1; reactive > target {
			target = reactive
		}
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

// headroomTarget is the proactive floor: the warm count needed so that, at
// current load, enough spare serving capacity is still FREE to absorb the demand
// growth expected while a cold provider is loading.
//
// Total serving capacity is warm·qc and the in-flight load occupies `occupied`
// slots, so requiring `headroom` providers' worth of free capacity gives
//
//	warm·qc - occupied >= headroom·qc
//	warm             >= ceil(occupied/qc) + headroom
//
// Note what is deliberately NOT in that expression: WarmSaturated. A saturated
// provider's capacity is already counted inside warm·qc and the requests
// occupying it are already counted inside `occupied`, so adding it again
// double-counts — on a fully-busy pool that inflated the floor by one provider
// per saturated provider. WarmSaturated remains plumbed through for the pressure
// gate and the tick log, where it is a genuine signal.
//
// `headroom` itself is DERIVED per model, not configured: it is the measured
// occupancy ramp (slots of growth per control interval, EWMA) scaled by how many
// intervals a cold load takes, converted to providers by qc. See
// headroomProviders.
func headroomTarget(in warmTargetInputs, p warmTargetParams, qc int) int {
	headroom := headroomProviders(in, p, qc)
	if headroom <= 0 {
		return 0
	}
	if qc < 1 {
		qc = 1
	}
	occupied := in.RunningRequests + in.WaitingRequests + in.QueueDepth
	if occupied < 0 {
		occupied = 0
	}
	return int(math.Ceil(float64(occupied)/float64(qc))) + headroom
}

// headroomProviders resolves how many providers' worth of FREE capacity this model
// should keep warm.
//
// Precedence:
//  1. disabled outright -> 0 (purely reactive, pre-2026-09 behaviour)
//  2. an explicit per-model operator override -> that value
//  3. DERIVED from measurement: ceil(OccupancyRamp · loadWindows / qc)
//
// The derived form is the default because the correct value is a property of the
// model's own traffic shape, not a fleet-wide constant. OccupancyRamp is the
// smoothed per-interval RISE in occupied slots, so it answers the question the
// floor actually needs answered — "how much new demand shows up while a cold box
// is still loading?" — rather than "how much traffic is there?", which would size
// headroom to total volume and demand far more hardware than the fleet has.
//
// A model with no measured ramp yet gets 0 and stays purely reactive until it has
// samples, which is the conservative direction: no proactive warming on a guess.
func headroomProviders(in warmTargetInputs, p warmTargetParams, qc int) int {
	if !p.HeadroomEnabledParams {
		return 0
	}
	if n, ok := p.HeadroomProviders[in.Model]; ok {
		if n < 0 {
			return 0
		}
		return n
	}
	if in.OccupancyRamp <= 0 {
		return 0
	}
	if qc < 1 {
		qc = 1
	}
	windows := p.HeadroomLoadWindows
	if windows <= 0 {
		windows = 1
	}
	slots := in.OccupancyRamp * windows
	providers := int(math.Ceil(slots / float64(qc)))
	if providers < 1 {
		providers = 1
	}
	if p.HeadroomMaxProviders > 0 && providers > p.HeadroomMaxProviders {
		providers = p.HeadroomMaxProviders
	}
	return providers
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
