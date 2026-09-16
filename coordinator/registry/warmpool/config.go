package warmpool

import (
	"fmt"
	"math"
	"time"
)

type Config struct {
	Enabled     bool
	ObserveOnly bool

	Interval time.Duration
	MinDwell time.Duration

	QueueAgeThreshold         time.Duration
	CapacityRejectThreshold   int
	WarmSaturationThreshold   float64
	TTFTMissThreshold         int
	SpeculativeStartThreshold int
	SpeculativeWinThreshold   int
	ColdDispatchThreshold     int
	LoadDurationThreshold     time.Duration

	// Little's Law target inputs (see target.go).
	//
	// DecodeFloorTPS is the per-request sustained-decode quality floor used to
	// derive per-provider quality concurrency (the max batch before decode drops
	// below the floor). <= 0 disables the quality constraint. BurstBuffer adds
	// spare warm providers on top of the demand-derived target. The Assumed*Tokens
	// size the representative request for the E[S] service-time estimate, and
	// FallbackQualityConcurrency is the per-provider concurrency used when the
	// floor/rates/caps are unknown.
	DecodeFloorTPS float64
	BurstBuffer    int
	// HeadroomEnabled turns the proactive warm-capacity floor on (default true).
	// When false the controller is purely reactive: the pool can only grow after a
	// capacity_reject / ttft_miss / cold_dispatch, then at +1 provider per tick.
	// EIGENINFERENCE_WARM_POOL_HEADROOM.
	HeadroomEnabled bool
	// HeadroomProviders is a per-model OVERRIDE map, e.g.
	// EIGENINFERENCE_WARM_POOL_HEADROOM_PROVIDERS="gpt-oss-20b=9,gemma-4-26b-qat-4bit=33".
	// Unlisted models use the DERIVED floor (measured occupancy ramp / qc), which
	// is the intended normal operation — the right value is a property of a
	// model's traffic shape, and measured across the live fleet it spans 2..33
	// providers. Use an entry only to pin a build whose measurement is not yet
	// trustworthy.
	//
	// NOTE: values must be >= 1. envModelIntMap (shared with MIN_WARM) drops
	// non-positive entries, so "model=0" is silently ignored rather than pinning a
	// model to zero headroom — to exempt one model, set HEADROOM_MAX_PROVIDERS or
	// disable the floor fleet-wide instead.
	HeadroomProviders map[string]int
	// HeadroomMaxProviders caps any single model's DERIVED floor so a pathological
	// ramp cannot demand the whole fleet. Overrides are not capped — an operator
	// naming a number means it. <= 0 is uncapped.
	HeadroomMaxProviders int
	// HeadroomLoadWindows is how many control intervals of demand growth the floor
	// should cover, approximating cold-load time (prod: 30s interval, ~20-30s
	// load, so ~1). <= 0 falls back to 1.
	HeadroomLoadWindows        float64
	FallbackQualityConcurrency int
	AssumedPromptTokens        int
	AssumedCompletionTokens    int
	// MinWarmByModel is an operator floor for concrete model IDs, e.g.
	// EIGENINFERENCE_WARM_POOL_MIN_WARM="gpt-oss-20b=4,gemma-4-26b-qat-4bit=2".
	// Floors are capped by warm+eligibleCold and still obey load throttles.
	MinWarmByModel map[string]int

	// Ramp shaping. MaxLoadsPerTick is the baseline per-tick load burst;
	// RampGapFraction scales the burst up with the remaining target gap, bounded
	// by MaxLoadsPerTickCeiling (a sane hard maximum). MaxGlobalPendingLoads caps
	// total in-flight loads across the fleet.
	MaxLoadsPerTick        int
	MaxLoadsPerTickCeiling int
	RampGapFraction        float64
	MaxGlobalPendingLoads  int
}

// perTickCeiling is the hard per-tick load cap after demand scaling. It is the
// larger of MaxLoadsPerTick and MaxLoadsPerTickCeiling, and 0 when per-tick loads
// are disabled (MaxLoadsPerTick <= 0), which keeps the controller in observe-only
// behavior for the load-issuing path.
func (c Config) PerTickCeiling() int {
	if c.MaxLoadsPerTick <= 0 {
		return 0
	}
	if c.MaxLoadsPerTickCeiling > c.MaxLoadsPerTick {
		return c.MaxLoadsPerTickCeiling
	}
	return c.MaxLoadsPerTick
}

func (c Config) Check() error {
	// The decode floor also feeds admission when the warm controller is disabled.
	for _, value := range []float64{c.WarmSaturationThreshold, c.DecodeFloorTPS, c.RampGapFraction, c.HeadroomLoadWindows} {
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return fmt.Errorf("registry: warm pool target tunables must be finite")
		}
	}
	if !c.Enabled && c.Interval == 0 {
		return nil
	}
	if c.Interval <= 0 {
		return fmt.Errorf("registry: warm pool interval must be > 0")
	}
	if c.MinDwell < 0 || c.QueueAgeThreshold < 0 || c.LoadDurationThreshold < 0 {
		return fmt.Errorf("registry: warm pool durations must be >= 0")
	}
	if c.WarmSaturationThreshold < 0 || c.WarmSaturationThreshold > 1 {
		return fmt.Errorf("registry: warm pool saturation threshold must be in [0,1]")
	}
	if c.CapacityRejectThreshold < 1 || c.TTFTMissThreshold < 1 || c.SpeculativeStartThreshold < 1 || c.SpeculativeWinThreshold < 1 || c.ColdDispatchThreshold < 1 {
		return fmt.Errorf("registry: warm pool pressure thresholds must be >= 1")
	}
	if c.MaxLoadsPerTick < 0 || c.MaxGlobalPendingLoads < 0 || c.MaxLoadsPerTickCeiling < 0 {
		return fmt.Errorf("registry: warm pool load limits must be >= 0")
	}
	if c.DecodeFloorTPS < 0 || c.BurstBuffer < 0 || c.RampGapFraction < 0 || c.HeadroomMaxProviders < 0 || c.HeadroomLoadWindows < 0 {
		return fmt.Errorf("registry: warm pool target tunables must be >= 0")
	}
	if c.AssumedPromptTokens < 0 || c.AssumedCompletionTokens < 0 {
		return fmt.Errorf("registry: warm pool assumed token counts must be >= 0")
	}
	if c.FallbackQualityConcurrency < 1 {
		return fmt.Errorf("registry: warm pool fallback quality concurrency must be >= 1")
	}
	return nil
}
