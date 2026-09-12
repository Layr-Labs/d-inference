package assert

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

type Threshold struct {
	Segment   testbed.Segment
	MaxMean   time.Duration
	MaxP95    time.Duration
	MaxP99    time.Duration
	MaxMedian time.Duration
}

type AssertionResult struct {
	Name    string `json:"name"`
	Passed  bool   `json:"passed"`
	Message string `json:"message,omitempty"`
}

type AssertionReport struct {
	Timestamp time.Time         `json:"timestamp"`
	Passed    bool              `json:"passed"`
	Results   []AssertionResult `json:"results"`
}

type Asserter struct {
	thresholds []Threshold
}

func NewAsserter(thresholds []Threshold) *Asserter {
	return &Asserter{thresholds: thresholds}
}

func DefaultThresholds() []Threshold {
	return []Threshold{
		{Segment: testbed.SegmentTotalE2E, MaxMean: 2 * time.Minute, MaxP95: 5 * time.Minute},
		{Segment: testbed.SegmentTTFT, MaxMean: 30 * time.Second, MaxP95: 90 * time.Second},
		{Segment: testbed.SegmentQueueWait, MaxMean: 30 * time.Second, MaxP95: 120 * time.Second},
	}
}

func CoordinatorOverheadThresholds() []Threshold {
	return []Threshold{
		{Segment: testbed.SegmentParse, MaxMean: 1 * time.Millisecond, MaxP95: 5 * time.Millisecond},
		{Segment: testbed.SegmentReserve, MaxMean: 50 * time.Millisecond, MaxP95: 200 * time.Millisecond},
		{Segment: testbed.SegmentEncrypt, MaxMean: 5 * time.Millisecond, MaxP95: 50 * time.Millisecond},
		{Segment: testbed.SegmentDispatch, MaxMean: 5 * time.Millisecond, MaxP95: 50 * time.Millisecond},
	}
}

type SegmentStatsView = testbed.SegmentStatsView

func (a *Asserter) Evaluate(stats map[testbed.Segment]*SegmentStatsView) *AssertionReport {
	report := &AssertionReport{
		Timestamp: time.Now(),
		Passed:    true,
	}

	for _, t := range a.thresholds {
		s, ok := stats[t.Segment]
		if !ok || s == nil || s.Count <= 0 {
			report.Results = append(report.Results, AssertionResult{
				Name:    fmt.Sprintf("%s:present", t.Segment),
				Passed:  false,
				Message: fmt.Sprintf("no data for segment %s", t.Segment),
			})
			report.Passed = false
			continue
		}

		for _, check := range []struct {
			name       string
			value, max time.Duration
		}{
			{"mean", s.Mean, t.MaxMean},
			{"p95", s.P95, t.MaxP95},
			{"p99", s.P99, t.MaxP99},
			{"median", s.Median, t.MaxMedian},
		} {
			if check.max <= 0 {
				continue
			}
			passed := check.value <= check.max
			report.Results = append(report.Results, AssertionResult{
				Name:    fmt.Sprintf("%s:%s<=%s", t.Segment, check.name, check.max),
				Passed:  passed,
				Message: fmt.Sprintf("%s=%s (threshold=%s)", check.name, check.value, check.max),
			})
			if !passed {
				report.Passed = false
			}
		}
	}

	return report
}

func (r *AssertionReport) SummaryMarkdown() string {
	status := "PASS"
	if !r.Passed {
		status = "FAIL"
	}
	s := fmt.Sprintf("### Assertion Report: %s\n\n", status)
	s += "| Assertion | Result | Detail |\n|---|---|---|\n"
	for _, result := range r.Results {
		icon := "PASS"
		if !result.Passed {
			icon = "FAIL"
		}
		s += fmt.Sprintf("| %s | %s | %s |\n", result.Name, icon, result.Message)
	}
	return s
}

func (r *AssertionReport) SummaryTable() string {
	status := "PASS"
	if !r.Passed {
		status = "FAIL"
	}
	s := fmt.Sprintf("Assertion Report: %s\n", status)
	s += fmt.Sprintf("%-50s %6s %s\n", "ASSERTION", "RESULT", "DETAIL")
	s += "───────────────────────────────────────────────────────────────────\n"
	for _, result := range r.Results {
		icon := "PASS"
		if !result.Passed {
			icon = "FAIL"
		}
		s += fmt.Sprintf("%-50s %6s %s\n", result.Name, icon, result.Message)
	}
	return s
}
