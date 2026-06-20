package baserewards

import (
	"math"
	"testing"
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

func TestScaledFloor(t *testing.T) {
	// 64GB tier ($18) at 95% uptime (avail=0.5), taper=1 → $9.
	if got := ScaledFloor(64, 0.95, 1.0); got != 9_000_000 {
		t.Errorf("ScaledFloor(64, 0.95, 1.0) = %d, want 9_000_000", got)
	}
	// Full uptime, full taper → full tier floor.
	if got := ScaledFloor(64, 1.0, 1.0); got != 18_000_000 {
		t.Errorf("ScaledFloor(64, 1.0, 1.0) = %d, want 18_000_000", got)
	}
	// Below 90% uptime → 0 regardless of tier.
	if got := ScaledFloor(512, 0.89, 1.0); got != 0 {
		t.Errorf("ScaledFloor(512, 0.89, 1.0) = %d, want 0", got)
	}
	// Half taper on top of full availability.
	if got := ScaledFloor(64, 1.0, 0.5); got != 9_000_000 {
		t.Errorf("ScaledFloor(64, 1.0, 0.5) = %d, want 9_000_000", got)
	}
	// 32GB entry tier ($12) at full uptime/taper.
	if got := ScaledFloor(32, 1.0, 1.0); got != 12_000_000 {
		t.Errorf("ScaledFloor(32, 1.0, 1.0) = %d, want 12_000_000", got)
	}
	// Sub-24GB tier → 0.
	if got := ScaledFloor(16, 1.0, 1.0); got != 0 {
		t.Errorf("ScaledFloor(16, 1.0, 1.0) = %d, want 0", got)
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
