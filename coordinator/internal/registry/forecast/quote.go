package forecast

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Quote carries request-local readiness evidence, not replacement measurements.
type Quote struct {
	Confirmed, Demoted bool
	Confidence         string
	ObservedAt         time.Time
	CapacitySeq        uint64
	TTFTP50, TTFTP90   time.Duration
}

type QuoteContext struct {
	CapacitySeq         uint64
	NewestReservationAt time.Time
}

func ApplyQuote(result Result, evidence Evidence, request Request, quote Quote, current QuoteContext, now time.Time) Estimate {
	e := result.Estimate
	if !quote.Confirmed || quote.Demoted || quote.Confidence != protocol.CapacityConfidenceHigh ||
		quote.ObservedAt.IsZero() || now.Before(quote.ObservedAt) || now.Sub(quote.ObservedAt) > CapacityFreshness ||
		quote.CapacitySeq < current.CapacitySeq || current.NewestReservationAt.After(quote.ObservedAt) ||
		(!request.FreshAfter.IsZero() && !quote.ObservedAt.After(request.FreshAfter)) ||
		quote.TTFTP50 <= 0 || quote.TTFTP90 < quote.TTFTP50 ||
		(request.Deadline.IsZero() && (!(request.Hedge || request.RequireFreshFeasible) || request.PlanningHorizon <= 0)) ||
		UnknownReason(evidence, request, result.Calibrated, true) != "" {
		return e
	}
	// Quantiles cannot erase local measured work or the current restore charge.
	e.ExpectedMs = max(e.ExpectedMs, float64(quote.TTFTP50)/float64(time.Millisecond)+e.RestoreMs)
	e.ConservativeMs = max(e.ConservativeMs, float64(quote.TTFTP90)/float64(time.Millisecond)+e.RestoreMs)
	if request.Deadline.IsZero() {
		e.BudgetMs = float64(request.PlanningHorizon) / float64(time.Millisecond)
	} else {
		e.BudgetMs = max(0, float64(request.Deadline.Sub(now))/float64(time.Millisecond))
	}
	e.Status, e.Reason = Feasible, "fresh_quote"
	if e.ConservativeMs > e.BudgetMs {
		e.Status = PredictedLate
	}
	return e
}

// BackupTiming retains both local evidence freshness and quoted readiness.
func BackupTiming(estimate Estimate, qualified bool, forecastAt time.Time, quote Quote, now time.Time) (time.Duration, bool) {
	age := now.Sub(forecastAt)
	if !qualified || forecastAt.IsZero() || age < 0 ||
		time.Duration(estimate.CapacityAgeMs)*time.Millisecond+age > CapacityFreshness ||
		time.Duration(estimate.PerformanceAgeMs)*time.Millisecond+age > PerformanceFreshness {
		return 0, false
	}
	if quote.Confirmed && !quote.Demoted && quote.Confidence == protocol.CapacityConfidenceHigh &&
		!quote.ObservedAt.IsZero() && !now.Before(quote.ObservedAt) && now.Sub(quote.ObservedAt) <= CapacityFreshness {
		return max(time.Duration(estimate.ConservativeMs*float64(time.Millisecond)), quote.TTFTP90+time.Duration(estimate.RestoreMs*float64(time.Millisecond))), true
	}
	return 0, false
}
