package performance

import "github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"

// Rates projects detached measurements without owning serving or admission state.
// ExploredPrefill and ExploredDecode are fleet medians that replace the
// provider's own rate while evidence exploration prices it; 0 keeps the
// ordinary order. A reviewed profile point still comes first. EffectiveDecode
// and Prefill use them; ProjectedDecode does not.
type Rates struct {
	Profile                                   *Profile
	StaticPrefill, ObservedPrefill            float64
	StaticDecode, ObservedDecode, FleetMedian float64
	ExploredPrefill, ExploredDecode           float64
	ObservedBatch, Occupancy                  int
}

// EffectiveDecode resolves the current batch rate, not a new request's join rate.
func (r Rates) EffectiveDecode(loadFactor float64) float64 {
	if point, ok := r.Profile.BatchAt(max(1, r.Occupancy+1)); ok {
		return point.DecodeP10TPS
	}
	if r.ExploredDecode > 0 {
		return r.ExploredDecode
	}
	if r.ObservedDecode > 0 {
		return r.ObservedDecode
	}
	if r.FleetMedian > 0 {
		return r.FleetMedian
	}
	return EffectiveDecode(r.StaticDecode, r.ObservedBatch, loadFactor)
}

// EffectiveDecode scales a static rate by current load, floored at one token/s.
func EffectiveDecode(staticTPS float64, backendRunning int, loadFactor float64) float64 {
	if staticTPS <= 0 {
		return 1.0
	}
	if loadFactor <= 0 || backendRunning <= 0 {
		return staticTPS
	}
	tps := staticTPS / (1.0 + loadFactor*float64(backendRunning))
	if tps < 1.0 {
		tps = 1.0
	}
	return tps
}

func (r Rates) Prefill() float64 {
	if point, ok := r.Profile.BatchAt(max(1, r.Occupancy+1)); ok {
		return point.PrefillTPS
	}
	tps := r.StaticPrefill
	switch {
	case capacityvalue.FinitePositive(r.ExploredPrefill):
		tps = r.ExploredPrefill
	case capacityvalue.FinitePositive(r.ObservedPrefill):
		tps = r.ObservedPrefill
	}
	if !capacityvalue.FinitePositive(tps) {
		tps = 1
	}
	return min(tps, capacityvalue.MaxPrefillTPS)
}

func (r Rates) ProjectedDecode(joinBatch int, loadFactor float64, useFleetMedian bool) float64 {
	if point, ok := r.Profile.BatchAt(max(1, joinBatch+1)); ok {
		return point.DecodeP10TPS
	}
	k := max(0, loadFactor)
	solo := r.StaticDecode
	switch {
	case r.ObservedDecode > 0:
		solo = r.ObservedDecode * (1 + k*float64(max(0, r.ObservedBatch)))
	case useFleetMedian && r.FleetMedian > 0:
		solo = r.FleetMedian
	}
	if solo <= 0 {
		return 0
	}
	return solo / (1 + k*float64(max(0, joinBatch)+1))
}
