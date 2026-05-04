package e2e

import (
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
	tbassert "github.com/eigeninference/d-inference/e2e/testbed/assert"
)

func TestProfile_SingleProviderStreaming(t *testing.T) {
	s := startSuite(t)

	cfg := testbed.DefaultRequestConfig()
	cfg.Streaming = true
	cfg.TotalRequests = 20
	cfg.Concurrency = 5
	cfg.MaxTokens = 64

	result := runProfiledLoad(t, s, cfg)

	t.Logf("\n%s", result.SummaryTable())

	assertReport := tbassert.NewAsserter(tbassert.CoordinatorOverheadThresholds()).Evaluate(result.SegmentStatsMap())
	t.Logf("\n%s", assertReport.SummaryTable())
	require.True(t, assertReport.Passed, "coordinator overhead thresholds exceeded")

	require.Greater(t, result.SuccessCount, 0, "at least some requests should succeed")
}

func TestProfile_SingleProviderNonStreaming(t *testing.T) {
	s := startSuite(t)

	cfg := testbed.DefaultRequestConfig()
	cfg.Streaming = false
	cfg.TotalRequests = 10
	cfg.Concurrency = 3
	cfg.MaxTokens = 32

	result := runProfiledLoad(t, s, cfg)

	t.Logf("\n%s", result.SummaryTable())

	assertReport := tbassert.NewAsserter(tbassert.CoordinatorOverheadThresholds()).Evaluate(result.SegmentStatsMap())
	t.Logf("\n%s", assertReport.SummaryTable())

	require.Greater(t, result.SuccessCount, 0)
}

func TestProfile_HighConcurrency(t *testing.T) {
	s := startSuite(t)

	cfg := testbed.DefaultRequestConfig()
	cfg.Streaming = true
	cfg.TotalRequests = 30
	cfg.Concurrency = 10
	cfg.MaxTokens = 32

	result := runProfiledLoad(t, s, cfg)

	t.Logf("\n%s", result.SummaryTable())

	assertReport := tbassert.NewAsserter(tbassert.CoordinatorOverheadThresholds()).Evaluate(result.SegmentStatsMap())
	t.Logf("\n%s", assertReport.SummaryTable())
	require.True(t, assertReport.Passed, "coordinator overhead thresholds exceeded under high concurrency")

	require.Greater(t, result.SuccessCount, 0)

	if result.SuccessCount > 1 {
		successDurations := make([]time.Duration, 0, result.SuccessCount)
		for _, rr := range result.RequestResults {
			if rr.StatusCode == http.StatusOK {
				successDurations = append(successDurations, rr.Duration)
			}
		}
		stats := computeSimpleStats(successDurations)
		t.Logf("Latency: mean=%s p50=%s p95=%s max=%s",
			stats.Mean.Round(time.Millisecond),
			stats.Median.Round(time.Millisecond),
			stats.P95.Round(time.Millisecond),
			stats.Max.Round(time.Millisecond),
		)
	}
}

func runProfiledLoad(t *testing.T, s *testbed.Suite, cfg testbed.RequestConfig) *testbed.LoadResult {
	t.Helper()

	lg := testbed.NewLoadGenerator(s, cfg)
	result := lg.Run()

	if result.ErrorCount > 0 {
		var sampleErrors []string
		for _, rr := range result.RequestResults {
			if rr.Error != nil && len(sampleErrors) < 3 {
				sampleErrors = append(sampleErrors, rr.Error.Error())
			}
		}
		t.Logf("errors (%d/%d): %v", result.ErrorCount, result.TotalRequests, sampleErrors)
	}

	return result
}

type simpleStats struct {
	Count  int
	Mean   time.Duration
	Median time.Duration
	P95    time.Duration
	Max    time.Duration
}

func computeSimpleStats(durations []time.Duration) simpleStats {
	if len(durations) == 0 {
		return simpleStats{}
	}

	sorted := make([]time.Duration, len(durations))
	copy(sorted, durations)
	for i := 0; i < len(sorted)-1; i++ {
		for j := i + 1; j < len(sorted); j++ {
			if sorted[j] < sorted[i] {
				sorted[i], sorted[j] = sorted[j], sorted[i]
			}
		}
	}

	var total time.Duration
	for _, d := range sorted {
		total += d
	}
	mean := total / time.Duration(len(sorted))
	median := sorted[len(sorted)/2]
	p95Idx := len(sorted) * 95 / 100
	if p95Idx >= len(sorted) {
		p95Idx = len(sorted) - 1
	}

	return simpleStats{
		Count:  len(sorted),
		Mean:   mean,
		Median: median,
		P95:    sorted[p95Idx],
		Max:    sorted[len(sorted)-1],
	}
}
