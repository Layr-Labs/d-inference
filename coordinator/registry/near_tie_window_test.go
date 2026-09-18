package registry

import (
	"math"
	"testing"
)

// withNearTieWindowFraction snapshots and restores the package-level knob so
// each test runs in isolation, mirroring withTTFTConfig.
func withNearTieWindowFraction(t *testing.T, fraction float64) {
	t.Helper()
	prev := NearTieCostWindowFraction()
	t.Cleanup(func() { SetNearTieCostWindowFraction(prev) })
	SetNearTieCostWindowFraction(fraction)
}

// mkWorkCandidate builds a candidate whose cost splits explicitly into the
// request's own work term (thisReqMs) and everything else — queue, pending,
// backlog, health, capacity-rate and cold-state penalties. The widened band must
// key off the work term only, so tests need the two to differ.
func mkWorkCandidate(id string, workMs, loadMs float64, queue, pending int) *routingCandidate {
	c := mkCandidate(id, workMs+loadMs, queue, pending, 0)
	c.breakdown.ThisReqMs = workMs
	c.breakdown.QueueMs = loadMs
	c.breakdown.Total = workMs + loadMs
	return c
}

// withPenalty marks a candidate as one a derater deliberately sank.
func withPenalty(c *routingCandidate, health, capacityRate, state float64) *routingCandidate {
	c.breakdown.HealthMs = health
	c.breakdown.CapacityRateMs = capacityRate
	c.breakdown.StateMs = state
	return c
}

// TestNearTieWindowDefaultIsByteForByteUnchanged pins the neutral default: with
// the fraction at 0 the window is the fixed 3s absolute constant, so a candidate
// outside it is not a near-tie and cannot win on least-busy.
func TestNearTieWindowDefaultIsByteForByteUnchanged(t *testing.T) {
	if NearTieCostWindowFraction() != 0 {
		t.Fatalf("default near-tie fraction must be 0, got %f", NearTieCostWindowFraction())
	}
	fast := mkWorkCandidate("fast", 20_000, 0, 5, 5)
	slow := mkWorkCandidate("slow", 25_000, 0, 0, 0)
	winner, _, nearTie, _ := selectRoutingCandidate([]*routingCandidate{fast, slow})
	if winner != fast {
		t.Fatalf("default behavior changed: expected the cheapest candidate to win, got %s", winner.provider.ID)
	}
	if nearTie != 1 {
		t.Fatalf("expected a single near-tie under the absolute window, got %d", nearTie)
	}
}

// TestNearTieWindowScalesWithRequestWork is the starvation fix. The absolute
// 3000ms window shrinks in RELATIVE terms as the decode term grows with
// max_tokens, so on long requests only the fastest hardware stays inside it.
func TestNearTieWindowScalesWithRequestWork(t *testing.T) {
	withNearTieWindowFraction(t, 0.5) // band = max(3000, 0.5 * 20000) = 10000

	fast := mkWorkCandidate("fast", 20_000, 0, 5, 5)
	slow := mkWorkCandidate("slow", 25_000, 0, 0, 0)
	winner, _, nearTie, path := selectRoutingCandidate([]*routingCandidate{fast, slow})
	if nearTie != 2 {
		t.Fatalf("expected both candidates inside the widened band, got %d", nearTie)
	}
	if winner != slow {
		t.Fatalf("expected the idle candidate to win on least-busy, got %s", winner.provider.ID)
	}
	if path != SelectionTieQueue {
		t.Fatalf("expected the queue tie-break path, got %s", path)
	}
}

// TestNearTieWindowIgnoresLoadTerms is review finding 1. The band must scale on
// the request's own work, NOT on total cost. Scaling on total cost widens the
// band most under load — exactly when concentrating on the fastest node is
// correct — and re-admits nodes the load terms were meant to sink.
func TestNearTieWindowIgnoresLoadTerms(t *testing.T) {
	withNearTieWindowFraction(t, 0.5)

	// Work is small (2000ms); the winner's cost is dominated by queue load
	// (15000ms from 5 in-flight requests). Band must be max(3000, 0.5*2000) =
	// 3000 — NOT 0.5*17000 = 8500.
	fast := mkWorkCandidate("fast", 2_000, 15_000, 5, 5)
	slow := mkWorkCandidate("slow", 22_000, 0, 0, 0) // 5000ms worse than fast
	winner, _, nearTie, _ := selectRoutingCandidate([]*routingCandidate{fast, slow})
	if nearTie != 1 {
		t.Fatalf("load terms must not widen the band: expected 1 near-tie, got %d", nearTie)
	}
	if winner != fast {
		t.Fatalf("expected the loaded-but-cheaper candidate to win, got %s", winner.provider.ID)
	}
}

// TestWidenedBandNeverReadmitsADeratedCandidate is the second half of finding 1.
// The capacity-rate derater documents that it sinks a bad pair "well below the
// near-tie window"; thermal, memory-pressure and cold-state penalties do the
// same. Widening must never undo a derater.
func TestWidenedBandNeverReadmitsADeratedCandidate(t *testing.T) {
	withNearTieWindowFraction(t, 0.5) // band = 10000 on a 20000ms work term

	fast := mkWorkCandidate("fast", 20_000, 0, 5, 5)
	for _, tc := range []struct {
		name                        string
		health, capacityRate, state float64
	}{
		{"health", 4_000, 0, 0},
		{"capacity_rate", 0, 6_000, 0},
		{"cold_state", 0, 0, 20_000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// 6000ms worse than fast: outside the absolute 3000 floor, inside
			// the widened 10000 band, but carrying a derater's penalty.
			derated := withPenalty(mkWorkCandidate("derated", 26_000, 0, 0, 0),
				tc.health, tc.capacityRate, tc.state)
			winner, _, nearTie, _ := selectRoutingCandidate([]*routingCandidate{fast, derated})
			if nearTie != 1 {
				t.Fatalf("a derated candidate must stay outside the widened band, got %d near-ties", nearTie)
			}
			if winner != fast {
				t.Fatalf("derated candidate won selection: %s", winner.provider.ID)
			}
		})
	}
}

// TestNearTieWindowNeverShrinksBelowTheAbsoluteFloor guards the small-request
// case: a fractional band must widen the spread, never narrow it.
func TestNearTieWindowNeverShrinksBelowTheAbsoluteFloor(t *testing.T) {
	withNearTieWindowFraction(t, 0.5) // 0.5 * 100 = 50, far below the 3000 floor

	fast := mkWorkCandidate("fast", 100, 0, 5, 5)
	slow := mkWorkCandidate("slow", 2_000, 0, 0, 0)
	_, _, nearTie, _ := selectRoutingCandidate([]*routingCandidate{fast, slow})
	if nearTie != 2 {
		t.Fatalf("the absolute floor must still admit a 1900ms gap, got %d near-ties", nearTie)
	}
}

// TestNearTieWindowIgnoredWhenCacheAdjusted preserves the existing invariant:
// a pool carrying a live cache estimate ranks on exact adjusted cost with no
// window at all, and the fraction must not reopen one.
func TestNearTieWindowIgnoredWhenCacheAdjusted(t *testing.T) {
	withNearTieWindowFraction(t, 0.9)

	cached := mkCandidate("cached", 20_000, 5, 5, 500)
	cached.breakdown.ThisReqMs = 20_000
	other := mkCandidate("other", 25_000, 0, 0, 0)
	other.breakdown.ThisReqMs = 25_000
	winner, _, nearTie, _ := selectRoutingCandidate([]*routingCandidate{cached, other})
	if nearTie != 1 {
		t.Fatalf("cache-adjusted pools must use a zero window, got %d near-ties", nearTie)
	}
	if winner != cached {
		t.Fatalf("expected the cache-adjusted minimum to win, got %s", winner.provider.ID)
	}
}

// TestSetNearTieCostWindowFractionRejectsNonsense keeps a misconfigured value
// from silently disabling or exploding the band.
func TestSetNearTieCostWindowFractionRejectsNonsense(t *testing.T) {
	withNearTieWindowFraction(t, 0)

	for _, bad := range []float64{-1, math.NaN(), math.Copysign(0, -1)} {
		SetNearTieCostWindowFraction(bad)
		if got := NearTieCostWindowFraction(); got != 0 {
			t.Fatalf("%v must clamp to 0, got %f", bad, got)
		}
	}
	for _, big := range []float64{99, math.Inf(1)} {
		SetNearTieCostWindowFraction(big)
		if got := NearTieCostWindowFraction(); got != maxNearTieCostWindowFraction {
			t.Fatalf("%v must clamp to %f, got %f", big, maxNearTieCostWindowFraction, got)
		}
	}
}

// TestValidateNearTieWindowFractionMatchesSiblingKnobs pins the env-parsing
// contract: out-of-range input is REJECTED to the default rather than clamped up,
// so an operator typo cannot become maximal widening. Mirrors
// validateTTFTOccupancyAlpha.
func TestValidateNearTieWindowFractionMatchesSiblingKnobs(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want float64
		ok   bool
	}{
		{"0", 0, true},
		{"0.5", 0.5, true},
		{" 0.25 ", 0.25, true},
		{"1", 1, true},
		{"5", 0, false},
		{"-1", 0, false},
		{"NaN", 0, false},
		{"Inf", 0, false},
		{"abc", 0, false},
		{"", 0, false},
	} {
		got, ok := ValidateNearTieWindowFraction(tc.in)
		if ok != tc.ok || (ok && got != tc.want) {
			t.Fatalf("ValidateNearTieWindowFraction(%q) = (%v, %v), want (%v, %v)",
				tc.in, got, ok, tc.want, tc.ok)
		}
	}
}
