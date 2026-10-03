package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

func TestNormalizeUsageTimeSeriesRequestPreservesSafeWindow(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 7, 13, 4, 0, 0, 0, time.UTC)
	wantSince := now.Add(-time.Hour)
	since, until, bucket := shared.NormalizeUsageTimeSeriesRequest(wantSince, now, time.Minute, now)

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

func TestLimitUsageTimeSeriesBucketsKeepsNewestRows(t *testing.T) {
	t.Parallel()

	buckets := make([]store.UsageBucket, shared.UsageTimeSeriesMaxBuckets+2)
	for i := range buckets {
		buckets[i].Requests = int64(i)
	}

	bounded := shared.LimitUsageTimeSeriesBuckets(buckets)
	if len(bounded) != shared.UsageTimeSeriesMaxBuckets {
		t.Fatalf("len = %d, want %d", len(bounded), shared.UsageTimeSeriesMaxBuckets)
	}
	if bounded[0].Requests != 2 {
		t.Fatalf("first request count = %d, want 2", bounded[0].Requests)
	}
}
