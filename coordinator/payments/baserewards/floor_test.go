package baserewards

import (
	"math"
	"testing"
	"time"
)

func TestTierFloor(t *testing.T) {
	cases := []struct {
		memGB int
		want  int64
	}{
		{0, 0},
		{16, 0},
		{23, 0},
		{24, 10_000_000},
		{31, 10_000_000},
		{32, 12_000_000},
		{47, 12_000_000},
		{48, 16_000_000},
		{63, 16_000_000},
		{64, 18_000_000},
		{95, 18_000_000},
		{96, 22_000_000},
		{127, 22_000_000},
		{128, 26_000_000},
		{191, 26_000_000},
		{192, 30_000_000},
		{511, 30_000_000},
		{512, 40_000_000},
		{1024, 40_000_000},
	}
	for _, c := range cases {
		if got := TierFloor(c.memGB); got != c.want {
			t.Errorf("TierFloor(%d) = %d, want %d", c.memGB, got, c.want)
		}
	}
}

func TestAvail(t *testing.T) {
	cases := []struct {
		uptime float64
		want   float64
	}{
		{0.0, 0},
		{0.89, 0},
		{0.90, 0},
		{0.95, 0.5},
		{1.0, 1.0},
		{1.5, 1.0}, // clamp above 1.0
	}
	for _, c := range cases {
		if got := Avail(c.uptime); math.Abs(got-c.want) > 1e-9 {
			t.Errorf("Avail(%v) = %v, want %v", c.uptime, got, c.want)
		}
	}
}

func TestPeriodFloor(t *testing.T) {
	start := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(SettlementPeriod)
	// 64GB tier ($18/mo) at 95% uptime (avail=0.5), prorated for 5 minutes in Jan.
	if got := PeriodFloor(64, 0.95, start, end); got != 1_008 {
		t.Errorf("PeriodFloor(64, 0.95) = %d, want 1_008", got)
	}
	// Full uptime → 5-minute share of the monthly tier floor.
	if got := PeriodFloor(64, 1.0, start, end); got != 2_016 {
		t.Errorf("PeriodFloor(64, 1.0) = %d, want 2_016", got)
	}
	// Below 90% uptime → 0 regardless of tier.
	if got := PeriodFloor(512, 0.89, start, end); got != 0 {
		t.Errorf("PeriodFloor(512, 0.89) = %d, want 0", got)
	}
	// 32GB entry tier ($12) at full uptime.
	if got := PeriodFloor(32, 1.0, start, end); got != 1_344 {
		t.Errorf("PeriodFloor(32, 1.0) = %d, want 1_344", got)
	}
	// Sub-24GB tier → 0.
	if got := PeriodFloor(16, 1.0, start, end); got != 0 {
		t.Errorf("PeriodFloor(16, 1.0) = %d, want 0", got)
	}
}

func TestDraw_K0_AdditiveDefault(t *testing.T) {
	// k=0 (the default) is additive base income: the full floor is paid on top
	// of earnings regardless of how much the machine earned organically.
	if DefaultReductionK != 0.0 {
		t.Fatalf("DefaultReductionK = %v, want 0.0 (additive base income)", DefaultReductionK)
	}
	const floor = 18_000_000
	for _, earned := range []int64{0, 9_000_000, 18_000_000, 30_000_000} {
		if got := Draw(floor, earned, DefaultReductionK); got != floor {
			t.Errorf("Draw(%d, %d, 0) = %d, want %d (full floor, additive)", floor, earned, got, floor)
		}
	}
}

func TestDraw_K1(t *testing.T) {
	// k=1, floor=$18: the base shrinks dollar-for-dollar with earnings.
	const floor = 18_000_000
	cases := []struct {
		earned int64
		want   int64
	}{
		{0, 18_000_000},
		{9_000_000, 9_000_000},
		{18_000_000, 0},
		{30_000_000, 0}, // out-earned the floor → no draw, never negative
	}
	for _, c := range cases {
		if got := Draw(floor, c.earned, 1.0); got != c.want {
			t.Errorf("Draw(%d, %d, 1.0) = %d, want %d", floor, c.earned, got, c.want)
		}
	}
}

func TestDraw_KHalf(t *testing.T) {
	// k=0.5, floor=$18: base reduces at half the rate; phases out at 2× floor.
	const floor = 18_000_000
	cases := []struct {
		earned int64
		want   int64
	}{
		{0, 18_000_000},
		{9_000_000, 13_500_000}, // 18 - 0.5*9
		{18_000_000, 9_000_000}, // 18 - 0.5*18
		{36_000_000, 0},         // 18 - 0.5*36 = 0
		{50_000_000, 0},         // never negative
	}
	for _, c := range cases {
		if got := Draw(floor, c.earned, 0.5); got != c.want {
			t.Errorf("Draw(%d, %d, 0.5) = %d, want %d", floor, c.earned, got, c.want)
		}
	}
}
