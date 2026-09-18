package trial

import (
	"math"
	"testing"
)

func TestReservationTokens(t *testing.T) {
	for _, tc := range []struct{ prompt, output, n, want int64 }{
		{0, 1, 1, 1},
		{500, 1_000, 1, 1_500},
		{500, 1_000, 3, 4_500},
		{4_999_999, 1, 1, 5_000_000},
		{math.MaxInt64 - 1, 1, 1, math.MaxInt64},
	} {
		got, err := ReservationTokens(tc.prompt, tc.output, tc.n)
		if err != nil || got != tc.want {
			t.Errorf("ReservationTokens(%d,%d,%d) = %d,%v, want %d", tc.prompt, tc.output, tc.n, got, err, tc.want)
		}
	}
}

func TestReservationTokensRejectsInvalidAndOverflow(t *testing.T) {
	for _, tc := range [][3]int64{
		{-1, 1, 1}, {0, 0, 1}, {0, -1, 1}, {0, 1, 0}, {0, 1, -1},
		{math.MaxInt64, 1, 1}, {math.MaxInt64 - 1, 1, 2}, {1, 1, math.MaxInt64},
	} {
		if _, err := ReservationTokens(tc[0], tc[1], tc[2]); err == nil {
			t.Errorf("invalid or overflowing reservation accepted: %v", tc)
		}
	}
}
