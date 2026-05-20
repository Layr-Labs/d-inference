package e2e

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
	tbassert "github.com/eigeninference/d-inference/e2e/testbed/assert"
)

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
