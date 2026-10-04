package registry_test

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
)

// Without a live observed rate, prefer the fleet median over the static benchmark.
func TestProjectedDecodeTPS_DecodeFloorTiers(t *testing.T) {
	k := warmplan.DecodeLoadFactor
	approx := func(got, want float64) bool { return math.Abs(got-want) < 0.01 }

	// Tier 2: idle, no observed rate, fleet median 9, not static 23.
	got := (performance.Rates{StaticDecode: 23, FleetMedian: 9, ObservedBatch: 0}).ProjectedDecode(0, k, quality.DecodeFloorUseFleetMedian())
	if want := 9.0 / (1 + k*1); !approx(got, want) {
		t.Errorf("idle+median: got %.3f want %.3f (must use median 9, not static 23)", got, want)
	}

	// Tier 1: live observed rate wins, unwound from batch then reapplied.
	got = (performance.Rates{StaticDecode: 23, FleetMedian: 5, ObservedDecode: 20, ObservedBatch: 2}).ProjectedDecode(2, k, quality.DecodeFloorUseFleetMedian())
	if want := 20.0 * (1 + k*2) / (1 + k*3); !approx(got, want) {
		t.Errorf("observed wins: got %.3f want %.3f", got, want)
	}

	// Tier 3: no observed rate or median, so use the static benchmark.
	got = (performance.Rates{StaticDecode: 23, FleetMedian: 0, ObservedBatch: 0}).ProjectedDecode(0, k, quality.DecodeFloorUseFleetMedian())
	if want := 23.0 / (1 + k*1); !approx(got, want) {
		t.Errorf("static fallback: got %.3f want %.3f", got, want)
	}
}

func TestProjectedDecodeTPS_FleetMedianKillSwitch(t *testing.T) {
	t.Setenv("EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN", "false")
	k := warmplan.DecodeLoadFactor
	// Kill switch off: idle box ignores the median and falls to static 23.
	got := (performance.Rates{StaticDecode: 23, FleetMedian: 9, ObservedBatch: 0}).ProjectedDecode(0, k, quality.DecodeFloorUseFleetMedian())
	if want := 23.0 / (1 + k*1); math.Abs(got-want) > 0.01 {
		t.Errorf("kill switch off: got %.3f want %.3f (must use static, not median)", got, want)
	}
}
