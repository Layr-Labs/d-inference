package store_test

import (
	"testing"
	"time"
)

// TestNetworkTotalsReturnsErrorWhenUnavailable: a store that cannot run the
// aggregate reports an error instead of a zero row (which callers used to
// cache and serve as data).
func TestNetworkTotalsReturnsErrorWhenUnavailable(t *testing.T) {
	s := testPostgresStore(t)
	s.Close()
	if _, err := s.NetworkTotals(time.Now().Add(-24 * time.Hour)); err == nil {
		t.Fatal("NetworkTotals on a closed pool returned no error")
	}
}

// TestUsageAggregatesReturnErrorWhenUnavailable: the four usage aggregates
// behind /v1/stats report an error instead of zero totals, a zero count or a
// nil series when the statement cannot run, so the stats refresher can keep
// its last good value instead of caching a corrupted body.
func TestUsageAggregatesReturnErrorWhenUnavailable(t *testing.T) {
	s := testPostgresStore(t)
	s.Close()
	if _, err := s.UsageLocationBuckets(time.Now()); err == nil {
		t.Error("UsageLocationBuckets on a closed pool returned no error")
	}
	if _, err := s.UsageFlowBuckets(time.Now(), nil); err == nil {
		t.Error("UsageFlowBuckets on a closed pool returned no error")
	}
	since := time.Now().Add(-24 * time.Hour)
	if _, err := s.UsageTotals(); err == nil {
		t.Error("UsageTotals on a closed pool returned no error")
	}
	if _, err := s.UsageTotalsSince(since); err == nil {
		t.Error("UsageTotalsSince on a closed pool returned no error")
	}
	if _, err := s.UsageCountSince(since); err == nil {
		t.Error("UsageCountSince on a closed pool returned no error")
	}
	if _, err := s.UsageTimeSeries(since, time.Now(), time.Minute); err == nil {
		t.Error("UsageTimeSeries on a closed pool returned no error")
	}
}
