package dispatch

import (
	"testing"
	"time"
)

func TestDeadlineBucket_AndORViewClass(t *testing.T) {
	budget := 10 * time.Second
	cases := []struct {
		elapsed time.Duration
		budget  time.Duration
		want    string
		wantOR  string
	}{
		{0, 0, DeadlineBucketUnknown, OrClassClientGone},
		{time.Second, budget, deadlineBucketUnderHalf, OrClassClientGone},
		{4999 * time.Millisecond, budget, deadlineBucketUnderHalf, OrClassClientGone},
		{5 * time.Second, budget, deadlineBucketMid, OrClassClientGone},
		{7999 * time.Millisecond, budget, deadlineBucketMid, OrClassClientGone},
		{8 * time.Second, budget, deadlineBucketNearDeadline, orClassTimeout},
		{9800 * time.Millisecond, budget, deadlineBucketNearDeadline, orClassTimeout},
		{10 * time.Second, budget, deadlineBucketOver, orClassTimeout},
		{30 * time.Second, budget, deadlineBucketOver, orClassTimeout},
		{-time.Second, budget, DeadlineBucketUnknown, OrClassClientGone},
	}
	for _, tc := range cases {
		got := DeadlineBucket(tc.elapsed, tc.budget)
		if got != tc.want {
			t.Errorf("deadlineBucket(%s, %s) = %q, want %q", tc.elapsed, tc.budget, got, tc.want)
		}
		if or := orViewClassForClientGone(got); or != tc.wantOR {
			t.Errorf("orViewClassForClientGone(%q) = %q, want %q", got, or, tc.wantOR)
		}
	}
	if got := orViewClassForClientGone(DeadlineBucketNotApplicable); got != OrClassClientGone {
		t.Errorf("not_applicable bucket must be excluded, got %q", got)
	}
}
