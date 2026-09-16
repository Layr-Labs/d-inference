package usagetime

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func TestNormalizeUsageTimeSeriesRequestBoundsCardinality(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 4, 0, 0, 0, time.UTC)
	since, until, bucket := NormalizeRequest(time.Time{}, time.Time{}, time.Nanosecond, now)

	if want := now.Add(-MaxLookback); !since.Equal(want) {
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
	since, until, bucket := NormalizeRequest(wantSince, now, time.Minute, now)

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
	since, gotUntil, bucket := NormalizeRequest(
		until.Add(-MaxLookback),
		until,
		12*time.Hour,
		now,
	)

	if !since.Equal(until.Add(-MaxLookback)) || !gotUntil.Equal(until) {
		t.Fatalf("window = [%s, %s), want [%s, %s)", since, gotUntil, until.Add(-MaxLookback), until)
	}
	if bucket != 12*time.Hour {
		t.Fatalf("bucket = %s, want 12h", bucket)
	}
}

func TestLimitUsageTimeSeriesBucketsKeepsNewestRows(t *testing.T) {
	t.Parallel()

	buckets := make([]contracts.UsageBucket, MaxBuckets+2)
	for i := range buckets {
		buckets[i].Requests = int64(i)
	}

	bounded := LimitBuckets(buckets)
	if len(bounded) != MaxBuckets {
		t.Fatalf("len = %d, want %d", len(bounded), MaxBuckets)
	}
	if bounded[0].Requests != 2 {
		t.Fatalf("first request count = %d, want 2", bounded[0].Requests)
	}
}
