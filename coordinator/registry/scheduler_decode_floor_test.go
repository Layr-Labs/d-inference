package registry

import (
	"math"
	"testing"
)

// C5: when a box has no LIVE observed decode rate, projectedPerRequestDecodeTPS
// uses the durable per-(model,chip) fleet median (tier 2) instead of the static
// benchmark (tier 3) — so a historically-slow idle box is deprioritized before it
// gets packed. Live-observed (tier 1) still wins; absent a median it falls to static.
func TestProjectedDecodeTPS_DecodeFloorTiers(t *testing.T) {
	k := effectiveTPSLoadFactor
	approx := func(got, want float64) bool { return math.Abs(got-want) < 0.01 }

	// Tier 2: idle, no observed rate, fleet median 9 → uses 9, NOT static 23.
	got := projectedPerRequestDecodeTPS(routingSnapshot{decodeTPS: 23, fleetMedianTPS: 9, backendRunning: 0})
	if want := 9.0 / (1 + k*1); !approx(got, want) {
		t.Errorf("idle+median: got %.3f want %.3f (must use median 9, not static 23)", got, want)
	}

	// Tier 1: live observed rate wins over the median, unwound from batch then reapplied.
	got = projectedPerRequestDecodeTPS(routingSnapshot{decodeTPS: 23, fleetMedianTPS: 5, observedDecodeTPS: 20, backendRunning: 2})
	if want := 20.0 * (1 + k*2) / (1 + k*3); !approx(got, want) {
		t.Errorf("observed wins: got %.3f want %.3f", got, want)
	}

	// Tier 3: no observed, no median → static benchmark.
	got = projectedPerRequestDecodeTPS(routingSnapshot{decodeTPS: 23, fleetMedianTPS: 0, backendRunning: 0})
	if want := 23.0 / (1 + k*1); !approx(got, want) {
		t.Errorf("static fallback: got %.3f want %.3f", got, want)
	}
}

func TestProjectedDecodeTPS_FleetMedianKillSwitch(t *testing.T) {
	t.Setenv("EIGENINFERENCE_DECODE_FLOOR_USE_FLEET_MEDIAN", "false")
	k := effectiveTPSLoadFactor
	// Kill switch off: idle box ignores the median and falls to static 23.
	got := projectedPerRequestDecodeTPS(routingSnapshot{decodeTPS: 23, fleetMedianTPS: 9, backendRunning: 0})
	if want := 23.0 / (1 + k*1); math.Abs(got-want) > 0.01 {
		t.Errorf("kill switch off: got %.3f want %.3f (must use static, not median)", got, want)
	}
}
