package usagetime

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

const (
	MinBucket   = time.Minute
	MaxLookback = 30 * 24 * time.Hour
	MaxBuckets  = 1440
)

// normalizeUsageTimeSeriesRequest bounds both dimensions that control query
// cardinality. The public API uses much smaller fixed windows (at most 60
// buckets), while this store-level guard also protects future callers.
func NormalizeRequest(since, until time.Time, bucketSize time.Duration, now time.Time) (time.Time, time.Time, time.Duration) {
	now = now.UTC()
	if bucketSize < MinBucket {
		bucketSize = MinBucket
	}
	if until.IsZero() || until.After(now) {
		until = now
	} else {
		until = until.UTC()
	}

	earliest := until.Add(-MaxLookback)
	if since.IsZero() || since.Before(earliest) {
		since = earliest
	} else {
		since = since.UTC()
	}

	lookback := until.Sub(since)
	if lookback <= 0 {
		return since, until, bucketSize
	}

	minimumForBoundedResult := (lookback + time.Duration(MaxBuckets-1)) /
		time.Duration(MaxBuckets)
	minimumForBoundedResult = RoundDurationUp(minimumForBoundedResult, MinBucket)
	if bucketSize < minimumForBoundedResult {
		bucketSize = minimumForBoundedResult
	}
	return since, until, bucketSize
}

func RoundDurationUp(value, quantum time.Duration) time.Duration {
	if value <= 0 || quantum <= 0 {
		return value
	}
	return ((value + quantum - 1) / quantum) * quantum
}

func LimitBuckets(buckets []contracts.UsageBucket) []contracts.UsageBucket {
	if len(buckets) <= MaxBuckets {
		return buckets
	}
	return buckets[len(buckets)-MaxBuckets:]
}
