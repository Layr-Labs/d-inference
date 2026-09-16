package testbed

import (
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestLoadReportsPreservePercentilesAndInputOrder(t *testing.T) {
	durations := make([]time.Duration, 100)
	for i := range durations {
		durations[i] = time.Duration(100-i) * time.Microsecond
	}
	r := &LoadResult{ProfileRun: &ProfileRun{SegmentTimings: map[Segment][]time.Duration{
		SegmentParse: durations, SegmentQueueWait: nil, "custom": {7 * time.Millisecond},
	}}}
	stats := r.SegmentStatsMap()
	require.Equal(t, &SegmentStatsView{Count: 100, Mean: 50500 * time.Nanosecond,
		Median: 51 * time.Microsecond, P95: 96 * time.Microsecond,
		P99: 100 * time.Microsecond, Max: 100 * time.Microsecond}, stats[SegmentParse])
	require.NotContains(t, stats, SegmentQueueWait)
	require.Equal(t, 1, stats["custom"].Count)
	require.Contains(t, r.SummaryMarkdown(), "| parse | 100 | 51µs | 51µs | 96µs | 100µs |")
	require.NotContains(t, r.SummaryTable(), "custom")
	for i, duration := range durations {
		require.Equal(t, time.Duration(100-i)*time.Microsecond, duration)
	}
}

func TestLoadReportsKeepKnownSegmentOrderAndEmptyResults(t *testing.T) {
	r := &LoadResult{ProfileRun: &ProfileRun{SegmentTimings: map[Segment][]time.Duration{
		SegmentProviderAck: {2 * time.Millisecond}, SegmentTTFT: {3 * time.Millisecond},
		SegmentTotalE2E: {4 * time.Millisecond}, SegmentPreflight: {time.Millisecond},
	}}}
	for _, report := range []string{r.SummaryTable(), r.SummaryMarkdown()} {
		previous := -1
		for _, segment := range []Segment{SegmentTotalE2E, SegmentPreflight, SegmentProviderAck, SegmentTTFT} {
			index := strings.Index(report, string(segment))
			require.Greater(t, index, previous)
			previous = index
		}
	}
	require.Nil(t, (&LoadResult{}).SegmentStatsMap())
	require.Empty(t, (&LoadResult{ProfileRun: &ProfileRun{}}).SegmentStatsMap())
}
