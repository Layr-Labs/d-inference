package registry_test

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

// wantQualityCap is the cap effectiveMaxConcurrencyForModelRateLocked must
// produce for a provider whose per-slot/flat limit is base: the strict quality
// batch grown by the overcommit allowance, never below 1, never above base.
func wantQualityCap(solo, floor float64, base int, overcommit float64) int {
	capped := int(math.Ceil(float64(strictQualityBatch(solo, floor, effectiveTPSLoadFactor, base)) * overcommit))
	if capped < 1 {
		capped = 1
	}
	if capped < base {
		return capped
	}
	return base
}

// soloTPSForCap inverts wantQualityCap: the smallest solo decode rate at which a
// provider reporting `base` concurrent slots is actually granted all of them.
// The cap is monotone non-decreasing in the solo rate, so a bisection is exact
// to the returned tolerance. This is the number an operator needs to size
// EIGENINFERENCE_MODEL_SOLO_TPS_SEED, and the number that moves when k moves.
func soloTPSForCap(floor float64, base int, overcommit float64) float64 {
	lo, hi := 0.0, floor
	for wantQualityCap(hi, floor, base, overcommit) < base {
		lo, hi = hi, hi*2
		if hi > 1e6 {
			return math.Inf(1)
		}
	}
	for i := 0; i < 200 && hi-lo > 1e-9; i++ {
		mid := (lo + hi) / 2
		if wantQualityCap(mid, floor, base, overcommit) < base {
			lo = mid
		} else {
			hi = mid
		}
	}
	return hi
}

// maxOvercommitDilution is the largest factor by which admitting at the
// overcommitted cap can push per-request decode below the quality floor.
//
// The nominal allowance is the overcommit itself, but the realized one is
// strictly worse: cap = ceil(qc × overcommit) rounds UP, which at qc = 1 turns
// an overcommit of 1.2 into a factor of 2. With rate(B) = solo/(1+k·B), the
// quality batch's defining solo >= floor·(1+k·qc), and ceil(x) < x+1:
//
//	rate(cap) > floor·(1+k·qc) / (1 + k·(overcommit·qc + 1))
//
// That ratio is monotone in qc — increasing when overcommit < 1+k, decreasing
// otherwise — so its infimum is the worse of the qc = 1 endpoint and the
// qc → infinity asymptote (1/overcommit). Pinning the NOMINAL floor/overcommit
// instead would be pinning a bound the implementation does not provide: it
// holds at k = 0.27 by luck of the rounding and fails at k = 0.39.
func maxOvercommitDilution(k, overcommit float64) float64 {
	return math.Max((1+k+k*overcommit)/(1+k), overcommit)
}

// TestQualityConcurrencyMatchesDefiningInequality is the one place the closed
// form is pinned: floor((solo/floor - 1)/k) must agree with a search over the
// inequality it was solved from, across the whole realistic rate range and both
// sides of every clamp. Boundary rates (where the real-valued batch lands on an
// integer) are skipped — there the two derivations legitimately differ by one
// float ulp, and pinning ulps is not a contract.
func TestQualityConcurrencyMatchesDefiningInequality(t *testing.T) {
	const floor = 15.0
	for _, k := range []float64{0.27, effectiveTPSLoadFactor, 0.39, 0.5} {
		for _, limit := range []int{1, 4, 8, 24, 32} {
			for solo := 1.0; solo <= 200.0; solo += 0.25 {
				if b := (solo/floor - 1) / k; math.Abs(b-math.Round(b)) < 1e-9 {
					continue
				}
				want := strictQualityBatch(solo, floor, k, limit)
				if got := warmplan.QualityConcurrency(solo, floor, k, limit, 4); got != want {
					t.Fatalf("qualityConcurrency(solo=%.2f, floor=%.0f, k=%.2f, limit=%d) = %d, want %d (largest B with solo/(1+k·B) ≥ floor)",
						solo, floor, k, limit, got, want)
				}
			}
		}
	}
	// The batch it returns must actually hold the floor whenever the model can
	// (the clamp-to-1 case is the documented exception: a provider is never
	// fully closed).
	for _, solo := range []float64{16, 20, 23, 30, 57, 93, 99.5, 101.8} {
		b := warmplan.QualityConcurrency(solo, floor, effectiveTPSLoadFactor, 32, 4)
		if rate := solo / (1 + effectiveTPSLoadFactor*float64(b)); b > 1 && rate < floor {
			t.Fatalf("solo %.1f: quality batch %d projects %.2f tok/s, below the %.0f floor it is defined to hold", solo, b, rate, floor)
		}
	}
}
