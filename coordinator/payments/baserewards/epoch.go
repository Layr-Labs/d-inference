package baserewards

import (
	"fmt"
	"time"
)

// EpochID is a calendar-month identifier in "YYYY-MM" UTC form. Settlement is
// monthly (matches the "Netflix" framing — design §8).
type EpochID = string

// previousEpochID returns the "YYYY-MM" UTC epoch immediately before the one
// containing now. The hourly settlement loop targets the previous epoch so it
// only ever settles a closed month.
func previousEpochID(now time.Time) EpochID {
	u := now.UTC()
	firstOfMonth := time.Date(u.Year(), u.Month(), 1, 0, 0, 0, 0, time.UTC)
	prev := firstOfMonth.AddDate(0, 0, -1) // last day of the previous month
	return prev.Format("2006-01")
}

// epochBounds returns the half-open UTC interval [start, end) for a "YYYY-MM"
// epoch. end is the first instant of the following month, so an epoch is closed
// exactly when now >= end.
func epochBounds(epochID EpochID) (start, end time.Time, err error) {
	start, err = time.ParseInLocation("2006-01", epochID, time.UTC)
	if err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("baserewards: invalid epoch id %q: %w", epochID, err)
	}
	end = start.AddDate(0, 1, 0)
	return start, end, nil
}

// epochSeconds returns the length of an epoch in seconds (used to normalize
// covered uptime into a fraction).
func epochSeconds(start, end time.Time) float64 {
	return end.Sub(start).Seconds()
}
