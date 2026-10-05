package shared_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/internal/store/shared"
)

const usageTimeSeriesMaxLookback = 30 * 24 * time.Hour

func TestNormalizeUsageTimeSeriesRequestBoundsCardinality(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 4, 0, 0, 0, time.UTC)
	since, until, bucket := production.NormalizeUsageTimeSeriesRequest(time.Time{}, time.Time{}, time.Nanosecond, now)

	if want := now.Add(-usageTimeSeriesMaxLookback); !since.Equal(want) {
		t.Fatalf("since = %s, want %s", since, want)
	}
	if bucket != 30*time.Minute {
		t.Fatalf("bucket = %s, want 30m", bucket)
	}
	if !until.Equal(now) {
		t.Fatalf("until = %s, want %s", until, now)
	}
}

func TestNormalizeUsageTimeSeriesRequestCapsRelativeToCompletedWindow(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 7, 0, 0, 0, time.UTC)
	until := now.Truncate(12 * time.Hour)
	since, gotUntil, bucket := production.NormalizeUsageTimeSeriesRequest(
		until.Add(-usageTimeSeriesMaxLookback),
		until,
		12*time.Hour,
		now,
	)

	if !since.Equal(until.Add(-usageTimeSeriesMaxLookback)) || !gotUntil.Equal(until) {
		t.Fatalf("window = [%s, %s), want [%s, %s)", since, gotUntil, until.Add(-usageTimeSeriesMaxLookback), until)
	}
	if bucket != 12*time.Hour {
		t.Fatalf("bucket = %s, want 12h", bucket)
	}
}
