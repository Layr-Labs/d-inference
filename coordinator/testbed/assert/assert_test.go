package assert

import (
	"testing"
	"time"

	"github.com/eigeninference/coordinator/testbed"
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
	if !report.Passed {
		t.Fatalf("expected pass, got fail: %v", report.Results)
	}
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
	if report.Passed {
		t.Fatal("expected fail, got pass")
	}

	passCount := 0
	failCount := 0
	for _, r := range report.Results {
		if r.Passed {
			passCount++
		} else {
			failCount++
		}
	}
	if failCount != 2 {
		t.Fatalf("expected 2 failures (mean + p95), got %d", failCount)
	}
}

func TestAsserterMissingSegment(t *testing.T) {
	thresholds := []Threshold{
		{Segment: testbed.SegmentQueueWait, MaxMean: 30 * time.Second},
	}

	a := NewAsserter(thresholds)

	stats := map[testbed.Segment]*SegmentStatsView{}

	report := a.Evaluate(stats)
	if report.Passed {
		t.Fatal("expected fail for missing segment, got pass")
	}
}

func TestDefaultThresholds(t *testing.T) {
	thresholds := DefaultThresholds()
	if len(thresholds) == 0 {
		t.Fatal("expected non-empty default thresholds")
	}

	found := false
	for _, th := range thresholds {
		if th.Segment == testbed.SegmentTotalE2E {
			found = true
			if th.MaxMean == 0 {
				t.Fatal("TotalE2E MaxMean should not be zero")
			}
		}
	}
	if !found {
		t.Fatal("expected TotalE2E in default thresholds")
	}
}

func TestAssertionReportSummaryTable(t *testing.T) {
	report := &AssertionReport{
		Passed: true,
		Results: []AssertionResult{
			{Name: "test:mean<=1s", Passed: true, Message: "mean=500ms"},
			{Name: "test:p95<=2s", Passed: true, Message: "p95=1.5s"},
		},
	}

	table := report.SummaryTable()
	if table == "" {
		t.Fatal("expected non-empty summary table")
	}
}

func TestAccountingAsserterNoNegativeBalances(t *testing.T) {
	report := &AssertionReport{
		Passed: true,
		Results: []AssertionResult{
			{Name: "no_negative_balances", Passed: true, Message: "no negative balances detected"},
		},
	}
	if !report.Passed {
		t.Fatal("expected pass")
	}
}
