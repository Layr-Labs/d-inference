package assert

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAsserterEvaluatePass(t *testing.T) {
	thresholds := []Threshold{
		{Segment: testbed.SegmentTTFT, MaxMean: 10 * time.Second, MaxP95: 30 * time.Second},
	}

	a := NewAsserter(thresholds)

	stats := map[testbed.Segment]*SegmentStatsView{
		testbed.SegmentTTFT: {
			Count: 10,
			Mean:  2 * time.Second,
			P95:   5 * time.Second,
		},
	}

	report := a.Evaluate(stats)
	assert.True(t, report.Passed, "expected pass, got fail: %v", report.Results)
}

func TestAsserterEvaluateFail(t *testing.T) {
	thresholds := []Threshold{
		{Segment: testbed.SegmentTTFT, MaxMean: 1 * time.Second, MaxP95: 2 * time.Second},
	}

	a := NewAsserter(thresholds)

	stats := map[testbed.Segment]*SegmentStatsView{
		testbed.SegmentTTFT: {
			Count: 10,
			Mean:  5 * time.Second,
			P95:   10 * time.Second,
		},
	}

	report := a.Evaluate(stats)
	assert.False(t, report.Passed)

	var failCount int
	for _, r := range report.Results {
		if !r.Passed {
			failCount++
		}
	}
	assert.Equal(t, 2, failCount, "expected 2 failures (mean + p95)")
}

func TestAsserterMissingSegment(t *testing.T) {
	thresholds := []Threshold{
		{Segment: testbed.SegmentQueueWait, MaxMean: 30 * time.Second},
	}

	a := NewAsserter(thresholds)
	report := a.Evaluate(map[testbed.Segment]*SegmentStatsView{})
	assert.False(t, report.Passed, "expected fail for missing segment")
}

func TestDefaultThresholds(t *testing.T) {
	thresholds := DefaultThresholds()
	require.NotEmpty(t, thresholds)

	found := false
	for _, th := range thresholds {
		if th.Segment == testbed.SegmentTotalE2E {
			found = true
			assert.NotZero(t, th.MaxMean, "TotalE2E MaxMean should not be zero")
		}
	}
	assert.True(t, found, "expected TotalE2E in default thresholds")
}

func TestAssertionReportSummaryTable(t *testing.T) {
	report := &AssertionReport{
		Passed: true,
		Results: []AssertionResult{
			{Name: "test:mean<=1s", Passed: true, Message: "mean=500ms"},
			{Name: "test:p95<=2s", Passed: true, Message: "p95=1.5s"},
		},
	}

	assert.NotEmpty(t, report.SummaryTable())
}
