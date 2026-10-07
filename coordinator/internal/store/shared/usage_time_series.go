package shared

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	usageTimeSeriesMinBucket   = time.Minute
	usageTimeSeriesMaxLookback = 30 * 24 * time.Hour
	UsageTimeSeriesMaxBuckets  = 1440
)

// normalizeUsageTimeSeriesRequest bounds both dimensions that control query
// cardinality. The public API uses much smaller fixed windows (at most 60
// buckets), while this store-level guard also protects future callers.
func NormalizeUsageTimeSeriesRequest(since, until time.Time, bucketSize time.Duration, now time.Time) (time.Time, time.Time, time.Duration) {
	now = now.UTC()
	if bucketSize < usageTimeSeriesMinBucket {
		bucketSize = usageTimeSeriesMinBucket
	}
	if until.IsZero() || until.After(now) {
		until = now
	} else {
		until = until.UTC()
	}

	earliest := until.Add(-usageTimeSeriesMaxLookback)
	if since.IsZero() || since.Before(earliest) {
		since = earliest
	} else {
		since = since.UTC()
	}

	lookback := until.Sub(since)
	if lookback <= 0 {
		return since, until, bucketSize
	}

	minimumForBoundedResult := (lookback + time.Duration(UsageTimeSeriesMaxBuckets-1)) /
		time.Duration(UsageTimeSeriesMaxBuckets)
	minimumForBoundedResult = roundDurationUp(minimumForBoundedResult, usageTimeSeriesMinBucket)
	if bucketSize < minimumForBoundedResult {
		bucketSize = minimumForBoundedResult
	}
	return since, until, bucketSize
}

func roundDurationUp(value, quantum time.Duration) time.Duration {
	if value <= 0 || quantum <= 0 {
		return value
	}
	return ((value + quantum - 1) / quantum) * quantum
}

func LimitUsageTimeSeriesBuckets(buckets []store.UsageBucket) []store.UsageBucket {
	if len(buckets) <= UsageTimeSeriesMaxBuckets {
		return buckets
	}
	return buckets[len(buckets)-UsageTimeSeriesMaxBuckets:]
}
