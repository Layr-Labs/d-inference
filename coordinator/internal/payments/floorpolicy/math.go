// Package floorpolicy owns the integer arithmetic and UTC boundaries of
// Autopilot's daily inference-earnings floor. Ordinary base rewards are separate.
package floorpolicy

import (
	"errors"
	"time"
)

const BaselineDuration = 7 * 24 * time.Hour

// DailyFloor rounds only once, after multiplying the exact seven-day daily
// average by 110%. Splitting the quotient avoids an overflowing intermediate.
func DailyFloor(sevenDayMicroUSD int64) (int64, error) {
	if sevenDayMicroUSD < 0 {
		return 0, errors.New("negative inference earnings baseline")
	}
	return sevenDayMicroUSD/70*11 + sevenDayMicroUSD%70*11/70, nil
}

func Day(at time.Time) time.Time {
	at = at.UTC()
	return time.Date(at.Year(), at.Month(), at.Day(), 0, 0, 0, 0, time.UTC)
}

func ValidateDay(day, now time.Time) error {
	if day.IsZero() || !day.Equal(Day(day)) || !day.Before(Day(now)) {
		return errors.New("a closed UTC day is required")
	}
	return nil
}
