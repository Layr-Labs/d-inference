package registry

import (
	"math"
	"strconv"
	"strings"
)

// Request-proportional near-tie band.
//
// Selection spreads load only among candidates inside a near-tie window of the
// minimum cost (selectRoutingCandidateWithAffinity): within it the least-busy
// candidate wins, and fully equivalent candidates are drawn at random. Outside
// it, a candidate is not considered while a cheaper one is routable.
//
// That window, nearTieCostWindowMs, is an ABSOLUTE 3s, while the request's own
// work term — the decode estimate max_tokens/decode_tps (buildCandidateInto's
// thisReqMs) — grows linearly with the requested output length. The window is
// therefore wide in relative terms for a short request and vanishingly narrow
// for a long one: as max_tokens rises, the set of nodes that can be spread to
// collapses onto the fastest hardware. Slower nodes still win eventually — each
// in-flight request adds queueDepthPenaltyMs to the leader — but only once the
// leader is carrying roughly gap/queueDepthPenaltyMs concurrent requests. With
// the fleet far below saturation that rarely happens, so a stable fastest-subset
// absorbs the traffic while idle, eligible, attested nodes sit unused.
//
// nearTieCostWindowFraction opens a widened band proportional to the WORK term
// only. Two properties matter and are enforced here rather than left to the
// caller:
//
//  1. It scales on thisReqMs, never on total cost. Total cost also carries
//     queue, pending, backlog, health, capacity-rate and cold-state terms, so
//     scaling on it would widen the band most precisely when the fleet is loaded
//     and concentration is the correct behavior.
//  2. A candidate carrying a derater's penalty is never re-admitted by the
//     widened band. capacity_rate.go documents that it sinks a bad pair "well
//     below the near-tie window"; the thermal, memory-pressure, GPU-utilization
//     and cold-state penalties rely on the same margin. Widening must not
//     silently undo any of them.
//
// The default is 0, which keeps the fixed absolute window and makes selection
// byte-for-byte identical to the previous behavior.
var nearTieCostWindowFraction = 0.0

// maxNearTieCostWindowFraction bounds the knob. At 1.0 the band already spans
// every candidate whose cost is up to twice the work term of the cheapest.
const maxNearTieCostWindowFraction = 1.0

// SetNearTieCostWindowFraction sets the proportional band. Values that are not
// strictly positive (including NaN and negative zero) disable it; values above
// maxNearTieCostWindowFraction clamp to it. Must be called before serving
// starts, mirroring the other package-level routing knobs.
func SetNearTieCostWindowFraction(fraction float64) {
	switch {
	case !(fraction > 0): // also catches NaN
		nearTieCostWindowFraction = 0
	case fraction > maxNearTieCostWindowFraction:
		nearTieCostWindowFraction = maxNearTieCostWindowFraction
	default:
		nearTieCostWindowFraction = fraction
	}
}

// NearTieCostWindowFraction returns the configured proportional band.
func NearTieCostWindowFraction() float64 {
	return nearTieCostWindowFraction
}

// ValidateNearTieWindowFraction parses an env value, returning ok=false for
// anything unparseable, non-finite, negative, or above the maximum. Callers keep
// the default on !ok and warn, matching validateTTFTOccupancyAlpha — an
// out-of-range value is REJECTED rather than clamped up, so an operator typo
// ("5") cannot silently become maximal widening.
func ValidateNearTieWindowFraction(raw string) (float64, bool) {
	fraction, err := strconv.ParseFloat(strings.TrimSpace(raw), 64)
	if err != nil || math.IsNaN(fraction) || math.IsInf(fraction, 0) {
		return 0, false
	}
	if fraction < 0 || fraction > maxNearTieCostWindowFraction {
		return 0, false
	}
	return fraction, true
}

// nearTieBandMs resolves the widened band for a pool whose cheapest candidate
// has work term bestWorkMs. It is never narrower than the absolute window, so
// enabling the fraction can only widen spreading.
func nearTieBandMs(bestWorkMs float64) float64 {
	band := nearTieCostWindowMs
	if nearTieCostWindowFraction > 0 && bestWorkMs > 0 {
		if relative := nearTieCostWindowFraction * bestWorkMs; relative > band {
			band = relative
		}
	}
	return band
}

// eligibleForWidenedBand reports whether a candidate may be admitted by the
// widened band. A candidate carrying a health, capacity-rate or cold-state
// penalty was deliberately sunk by a derater and must clear the ordinary
// absolute window on its own merits.
func eligibleForWidenedBand(c *routingCandidate) bool {
	if c == nil {
		return false
	}
	b := c.breakdown
	return b.HealthMs == 0 && b.CapacityRateMs == 0 && b.StateMs == 0
}
