package baserewards

import (
	"testing"
	"time"
)

func TestPreviousEpochID_FiveMinutePeriod(t *testing.T) {
	cases := []struct {
		now  time.Time
		want string
	}{
		{time.Date(2026, 6, 20, 12, 34, 56, 0, time.UTC), "2026-06-20T12:25Z"},
		{time.Date(2026, 6, 20, 12, 35, 0, 0, time.UTC), "2026-06-20T12:30Z"},
		{time.Date(2026, 6, 1, 0, 1, 0, 0, time.UTC), "2026-05-31T23:55Z"},
	}
	for _, c := range cases {
		if got := previousEpochID(c.now); got != c.want {
			t.Errorf("previousEpochID(%s) = %q, want %q", c.now, got, c.want)
		}
	}
}

func TestEpochBounds_FiveMinutePeriod(t *testing.T) {
	start, end, err := epochBounds("2026-06-20T12:30Z")
	if err != nil {
		t.Fatal(err)
	}
	if want := time.Date(2026, 6, 20, 12, 30, 0, 0, time.UTC); !start.Equal(want) {
		t.Fatalf("start = %s, want %s", start, want)
	}
	if want := start.Add(5 * time.Minute); !end.Equal(want) {
		t.Fatalf("end = %s, want %s", end, want)
	}
}

func TestPeriodBudget_ProratesMonthlyPool(t *testing.T) {
	start := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(SettlementPeriod)
	// January has 8,928 five-minute periods, so $8,928/mo maps to exactly $1 per
	// period (1,000,000 micro-USD).
	if got := PeriodBudget(8_928_000_000, start, end); got != 1_000_000 {
		t.Fatalf("PeriodBudget = %d, want 1_000_000", got)
	}
}
