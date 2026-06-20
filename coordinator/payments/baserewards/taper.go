package baserewards

// taper.go holds the pure "the program sunsets as the platform earns" math
// (design §4b) and the per-machine cliff guard (design §4). All pure functions;
// wired into SettleEpoch in Phase 2.

// TargetRevenueMicroUSD is the trailing-30-day fleet organic revenue at which
// the revenue taper reaches 0 (program fully sunset). ≈3× the pool — the
// off-ramp handoff threshold (design §4b, Open Decision #5).
const TargetRevenueMicroUSD int64 = 27_000_000_000 // ≈ $27,000/mo

// DefaultCliffMaxDropFrac caps how far a machine's total monthly income
// (earned+draw) may fall month-over-month from a taper change (design §4).
const DefaultCliffMaxDropFrac float64 = 0.30

// RevenueTaper = clamp(1 - fleetRev30d/targetRevenue, 0, 1). It keys on
// absolute revenue (not a utilization ratio, which is a positive-feedback trap —
// design §4b): 1.0 at zero revenue, 0 once the fleet grosses targetRevenue.
func RevenueTaper(fleetOrganicRevenue30d, targetRevenue int64) float64 {
	if targetRevenue <= 0 {
		return 0
	}
	v := 1 - float64(fleetOrganicRevenue30d)/float64(targetRevenue)
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

// CalendarGlide returns the calendar component of the taper: 1.0 for days
// [0,30], linearly down to residual over (30,90], and residual after day 90
// (design §4b). residual is clamped to [0,1].
func CalendarGlide(daysSinceLaunch int, residual float64) float64 {
	if residual < 0 {
		residual = 0
	}
	if residual > 1 {
		residual = 1
	}
	switch {
	case daysSinceLaunch <= 30:
		return 1.0
	case daysSinceLaunch >= 90:
		return residual
	default:
		// Linear from 1.0 at day 30 to residual at day 90.
		frac := float64(daysSinceLaunch-30) / 60.0
		return 1.0 - frac*(1.0-residual)
	}
}

// Taper = min(calendarGlide, revenueTaper) — whichever fades the program faster
// wins (design §4b).
func Taper(calendarGlide, revenueTaper float64) float64 {
	if calendarGlide < revenueTaper {
		return calendarGlide
	}
	return revenueTaper
}

// CliffGuardedTotal raises a requested draw just enough that the machine's total
// income (earned+draw) does not fall more than maxDropFrac below prevTotal. It
// never lowers the draw below the requested value and never returns below 0
// (design §4). prevTotal<=0 (no prior epoch) leaves the draw unchanged.
func CliffGuardedTotal(earned, requestedDraw, prevTotal int64, maxDropFrac float64) int64 {
	if requestedDraw < 0 {
		requestedDraw = 0
	}
	if prevTotal <= 0 {
		return requestedDraw
	}
	floorTotal := int64(float64(prevTotal) * (1 - maxDropFrac))
	minDraw := floorTotal - earned
	if minDraw < 0 {
		minDraw = 0
	}
	if minDraw > requestedDraw {
		return minDraw
	}
	return requestedDraw
}
