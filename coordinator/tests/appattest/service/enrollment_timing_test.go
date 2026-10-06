package service_test

import (
	"testing"
	"time"

	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
)

func TestEnrollmentBackoffLeftMirrorsTheDecisionAtTheLatestFailure(t *testing.T) {
	now := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	ago := func(durations ...time.Duration) []time.Time {
		times := make([]time.Time, len(durations))
		for i, d := range durations {
			times[i] = now.Add(-d)
		}
		return times
	}
	for name, tc := range map[string]struct {
		times []time.Time
		want  time.Duration
	}{
		"no failures":                     {nil, 0},
		"two failures":                    {ago(time.Hour, 2*time.Hour), 0},
		"three within a day":              {ago(time.Hour, 2*time.Hour, 23*time.Hour), 5 * time.Hour},
		"oldest outside the latest's day": {ago(time.Hour, 2*time.Hour, 25*time.Hour+time.Second), 0},
		"backoff served":                  {ago(6*time.Hour, 7*time.Hour, 8*time.Hour), 0},
		"clock ahead is capped":           {ago(-time.Hour, time.Hour, 2*time.Hour), recovery.EnrollmentInvalidKeyBackoff},
	} {
		if got := recovery.EnrollmentBackoffLeft(tc.times, now); got != tc.want {
			t.Errorf("%s: left = %v, want %v", name, got, tc.want)
		}
	}
}
