package baserewards

import (
	"fmt"
	"math"
	"time"
)

const periodIDLayout = "2006-01-02T15:04Z"

// SettlementPeriod is how often base rewards accrue. The tier table stays
// monthly for provider-facing pricing; each settlement pays the prorated share
// of that monthly floor for this period.
const SettlementPeriod = 5 * time.Minute

// EpochID identifies a closed base-reward settlement period in UTC.
type EpochID = string

// previousEpochID returns the 5-minute UTC period immediately before the one
// containing now. The settlement loop targets the previous period so it only ever
// settles a closed window.
func previousEpochID(now time.Time) EpochID {
	periodStart := now.UTC().Truncate(SettlementPeriod)
	return periodStart.Add(-SettlementPeriod).Format(periodIDLayout)
}

// epochBounds returns the half-open UTC interval [start, end) for a 5-minute
// settlement period. end is the first instant of the following period, so an
// epoch is closed exactly when now >= end.
func epochBounds(epochID EpochID) (start, end time.Time, err error) {
	start, err = time.ParseInLocation(periodIDLayout, epochID, time.UTC)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("baserewards: invalid epoch id %q: %w", epochID, err)
	}
	end = start.Add(SettlementPeriod)
	return start, end, nil
}

// epochSeconds returns the length of an epoch in seconds (used to normalize
// covered uptime into a fraction).
func epochSeconds(start, end time.Time) float64 {
	return end.Sub(start).Seconds()
}

// periodMonthFraction returns the fraction of the period's calendar month
// covered by [start, end). A 5-minute settlement in a 30-day month is 1/8640 of
// the monthly floor and monthly pool.
func periodMonthFraction(start, end time.Time) float64 {
	if !end.After(start) {
		return 0
	}
	u := start.UTC()
	monthStart := time.Date(u.Year(), u.Month(), 1, 0, 0, 0, 0, time.UTC)
	monthEnd := monthStart.AddDate(0, 1, 0)
	monthSeconds := monthEnd.Sub(monthStart).Seconds()
	if monthSeconds <= 0 {
		return 0
	}
	return end.Sub(start).Seconds() / monthSeconds
}

// PeriodBudget returns the prorated pool budget for [start, end), rounded to the
// nearest micro-USD.
func PeriodBudget(monthlyBudgetMicroUSD int64, start, end time.Time) int64 {
	return int64(math.Round(float64(monthlyBudgetMicroUSD) * periodMonthFraction(start, end)))
}
