package baserewards

import (
	"math"
	"testing"
)

func approx(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestRevenueTaper(t *testing.T) {
	const target = 27_000_000_000
	cases := []struct {
		rev  int64
		want float64
	}{
		{0, 1.0},
		{target / 2, 0.5},
		{target, 0.0},
		{target * 2, 0.0}, // clamp at 0
	}
	for _, c := range cases {
		if got := RevenueTaper(c.rev, target); !approx(got, c.want) {
			t.Errorf("RevenueTaper(%d, %d) = %v, want %v", c.rev, target, got, c.want)
		}
	}
	// Zero/negative target → fully sunset (avoid div-by-zero).
	if got := RevenueTaper(1, 0); got != 0 {
		t.Errorf("RevenueTaper(1, 0) = %v, want 0", got)
	}
}

func TestCalendarGlide(t *testing.T) {
	const residual = 0.2
	cases := []struct {
		day  int
		want float64
	}{
		{0, 1.0},
		{30, 1.0},
		{60, 0.6}, // halfway from 1.0 to 0.2
		{90, 0.2},
		{120, 0.2}, // residual after day 90
	}
	for _, c := range cases {
		if got := CalendarGlide(c.day, residual); !approx(got, c.want) {
			t.Errorf("CalendarGlide(%d, %v) = %v, want %v", c.day, residual, got, c.want)
		}
	}
}

func TestTaper(t *testing.T) {
	// min of the two.
	if got := Taper(0.8, 0.3); !approx(got, 0.3) {
		t.Errorf("Taper(0.8, 0.3) = %v, want 0.3", got)
	}
	if got := Taper(0.2, 0.9); !approx(got, 0.2) {
		t.Errorf("Taper(0.2, 0.9) = %v, want 0.2", got)
	}
}

func TestCliffGuardedTotal(t *testing.T) {
	// No prior epoch → draw unchanged.
	if got := CliffGuardedTotal(5_000_000, 3_000_000, 0, 0.30); got != 3_000_000 {
		t.Errorf("CliffGuardedTotal(no prev) = %d, want 3_000_000", got)
	}
	// Prior total $20, max 30% drop → floor total $14. Earned $5 → min draw $9.
	// Requested draw $3 would give total $8 (60% drop) → raised to $9.
	if got := CliffGuardedTotal(5_000_000, 3_000_000, 20_000_000, 0.30); got != 9_000_000 {
		t.Errorf("CliffGuardedTotal(cliff) = %d, want 9_000_000", got)
	}
	// Requested draw already above the guard floor → unchanged (never lowers).
	if got := CliffGuardedTotal(5_000_000, 12_000_000, 20_000_000, 0.30); got != 12_000_000 {
		t.Errorf("CliffGuardedTotal(no-op) = %d, want 12_000_000", got)
	}
	// Earned alone already covers the floor total → min draw clamps to 0, draw unchanged.
	if got := CliffGuardedTotal(20_000_000, 1_000_000, 20_000_000, 0.30); got != 1_000_000 {
		t.Errorf("CliffGuardedTotal(earned covers) = %d, want 1_000_000", got)
	}
	// Negative requested draw normalizes to 0 before guarding.
	if got := CliffGuardedTotal(100_000_000, -5, 20_000_000, 0.30); got != 0 {
		t.Errorf("CliffGuardedTotal(neg draw, earned covers) = %d, want 0", got)
	}
}
