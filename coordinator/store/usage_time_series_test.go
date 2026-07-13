package store

import (
	"testing"
	"time"
)

func TestNormalizeUsageTimeSeriesRequestBoundsCardinality(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 4, 0, 0, 0, time.UTC)
	since, until, bucket := normalizeUsageTimeSeriesRequest(time.Time{}, time.Time{}, time.Nanosecond, now)

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

func TestNormalizeUsageTimeSeriesRequestPreservesSafeWindow(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 4, 0, 0, 0, time.UTC)
	wantSince := now.Add(-time.Hour)
	since, until, bucket := normalizeUsageTimeSeriesRequest(wantSince, now, time.Minute, now)

	if !since.Equal(wantSince) {
		t.Fatalf("since = %s, want %s", since, wantSince)
	}
	if bucket != time.Minute {
		t.Fatalf("bucket = %s, want 1m", bucket)
	}
	if !until.Equal(now) {
		t.Fatalf("until = %s, want %s", until, now)
	}
}

func TestNormalizeUsageTimeSeriesRequestCapsRelativeToCompletedWindow(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 7, 0, 0, 0, time.UTC)
	until := now.Truncate(12 * time.Hour)
	since, gotUntil, bucket := normalizeUsageTimeSeriesRequest(
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

func TestLimitUsageTimeSeriesBucketsKeepsNewestRows(t *testing.T) {
	t.Parallel()

	buckets := make([]UsageBucket, usageTimeSeriesMaxBuckets+2)
	for i := range buckets {
		buckets[i].Requests = int64(i)
	}

	bounded := limitUsageTimeSeriesBuckets(buckets)
	if len(bounded) != usageTimeSeriesMaxBuckets {
		t.Fatalf("len = %d, want %d", len(bounded), usageTimeSeriesMaxBuckets)
	}
	if bounded[0].Requests != 2 {
		t.Fatalf("first request count = %d, want 2", bounded[0].Requests)
	}
}
