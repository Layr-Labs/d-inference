package telemetry

import "testing"

func TestCrossesPowerOfTen(t *testing.T) {
	cases := []struct {
		before, after int64
		want          bool
	}{
		{0, 0, false}, {0, 1, true}, {1, 2, false}, {9, 10, true}, {10, 11, false},
		{5, 12, true}, {99, 100, true}, {100, 1000, true}, {101, 999, false}, {0, 256, true},
		// Near math.MaxInt64 the power-of-ten walk must stop at 10^18 instead
		// of overflowing and spinning: 10^18 is the last threshold.
		{1<<63 - 2, 1<<63 - 1, false}, {1e18 - 1, 1<<63 - 1, true}, {0, 1<<63 - 1, true},
	}
	for _, tc := range cases {
		if got := CrossesPowerOfTen(tc.before, tc.after); got != tc.want {
			t.Fatalf("CrossesPowerOfTen(%d, %d) = %v, want %v", tc.before, tc.after, got, tc.want)
		}
	}
}
