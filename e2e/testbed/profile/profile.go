package profile

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/e2e/testbed"
)

type SegmentStats struct {
	Segment testbed.Segment `json:"segment"`
	Count   int             `json:"count"`
	Min     time.Duration   `json:"min"`
	Max     time.Duration   `json:"max"`
	Mean    time.Duration   `json:"mean"`
	Median  time.Duration   `json:"median"`
	P95     time.Duration   `json:"p95"`
	P99     time.Duration   `json:"p99"`
	StdDev  time.Duration   `json:"std_dev"`
	Total   time.Duration   `json:"total"`
}

type RequestSummary struct {
	RequestID string         `json:"request_id"`
	Segments  []SegmentStats `json:"segments"`
	E2E       time.Duration  `json:"e2e"`
	Chunks    int            `json:"chunks"`
	Errored   bool           `json:"errored"`
}

type ProfileRun struct {
	Config     testbed.TestConfig                `json:"config"`
	Timestamp  time.Time                         `json:"timestamp"`
	Duration   time.Duration                     `json:"duration"`
	Requests   []RequestSummary                  `json:"requests"`
	Aggregated map[testbed.Segment]*SegmentStats `json:"aggregated"`
	Errors     int                               `json:"errors"`
}

type Profiler struct {
	config testbed.TestConfig
	buffer *testbed.EventBuffer
}

func NewProfiler(config testbed.TestConfig, buffer *testbed.EventBuffer) *Profiler {
	return &Profiler{
		config: config,
		buffer: buffer,
	}
}

func (p *Profiler) Consume(event testbed.Event) {
	p.buffer.Consume(event)
}

func (p *Profiler) BuildProfile() *ProfileRun {
	events := p.buffer.Events()

	run := &ProfileRun{
		Config:    p.config,
		Timestamp: time.Now(),
	}

	_ = events

	requestEvents := p.buffer.ByKind(testbed.EventRequestStart)
	requestIDs := make([]string, 0, len(requestEvents))
	for _, e := range requestEvents {
		requestIDs = append(requestIDs, e.RequestID)
	}

	allDurations := make(map[testbed.Segment][]time.Duration)

	for _, rid := range requestIDs {
		summary := RequestSummary{RequestID: rid}
		reqEvents := p.buffer.ByRequest(rid)

		for _, e := range reqEvents {
			if e.Kind == testbed.EventError {
				summary.Errored = true
				run.Errors++
			}
			if e.Kind == testbed.EventStreamChunk {
				summary.Chunks++
			}
			if e.Kind == testbed.EventSegmentEnd {
				dur := e.Duration
				seg := e.Segment
				allDurations[seg] = append(allDurations[seg], dur)
				summary.Segments = append(summary.Segments, SegmentStats{
					Segment: seg,
					Count:   1,
					Min:     dur,
					Max:     dur,
					Mean:    dur,
					Median:  dur,
					Total:   dur,
				})
				if seg == testbed.SegmentTotalE2E {
					summary.E2E = dur
				}
			}
		}

		run.Requests = append(run.Requests, summary)
	}

	run.Aggregated = make(map[testbed.Segment]*SegmentStats)
	for seg, durations := range allDurations {
		run.Aggregated[seg] = computeSegmentStats(seg, durations)
	}

	return run
}

func (p *Profiler) Diff(previous *ProfileRun) *ProfileDiff {
	current := p.BuildProfile()
	diff := &ProfileDiff{
		Previous: previous.Timestamp,
		Current:  current.Timestamp,
		Segments: make(map[testbed.Segment]*SegmentDiff),
	}

	for seg, cur := range current.Aggregated {
		d := &SegmentDiff{Current: cur}
		if prev, ok := previous.Aggregated[seg]; ok {
			d.Previous = prev
			d.MeanDelta = cur.Mean - prev.Mean
			d.MeanPctChange = pctChange(prev.Mean, cur.Mean)
			d.P95Delta = cur.P95 - prev.P95
			d.P95PctChange = pctChange(prev.P95, cur.P95)
		}
		diff.Segments[seg] = d
	}

	return diff
}

type SegmentDiff struct {
	Previous      *SegmentStats `json:"previous,omitempty"`
	Current       *SegmentStats `json:"current"`
	MeanDelta     time.Duration `json:"mean_delta"`
	MeanPctChange float64       `json:"mean_pct_change"`
	P95Delta      time.Duration `json:"p95_delta"`
	P95PctChange  float64       `json:"p95_pct_change"`
}

type ProfileDiff struct {
	Previous time.Time                        `json:"previous"`
	Current  time.Time                        `json:"current"`
	Segments map[testbed.Segment]*SegmentDiff `json:"segments"`
}

func computeSegmentStats(seg testbed.Segment, durations []time.Duration) *SegmentStats {
	if len(durations) == 0 {
		return &SegmentStats{Segment: seg}
	}

	sort.Slice(durations, func(i, j int) bool {
		return durations[i] < durations[j]
	})

	var total time.Duration
	for _, d := range durations {
		total += d
	}
	mean := total / time.Duration(len(durations))

	var sumSq float64
	for _, d := range durations {
		dev := float64(d - mean)
		sumSq += dev * dev
	}
	stdDev := time.Duration(math.Sqrt(sumSq / float64(len(durations))))

	p95Idx := int(math.Ceil(float64(len(durations))*0.95)) - 1
	p99Idx := int(math.Ceil(float64(len(durations))*0.99)) - 1
	if p95Idx >= len(durations) {
		p95Idx = len(durations) - 1
	}
	if p99Idx >= len(durations) {
		p99Idx = len(durations) - 1
	}

	medianIdx := len(durations) / 2

	return &SegmentStats{
		Segment: seg,
		Count:   len(durations),
		Min:     durations[0],
		Max:     durations[len(durations)-1],
		Mean:    mean,
		Median:  durations[medianIdx],
		P95:     durations[p95Idx],
		P99:     durations[p99Idx],
		StdDev:  stdDev,
		Total:   total,
	}
}

func pctChange(prev, cur time.Duration) float64 {
	if prev == 0 {
		return 0
	}
	return float64(cur-prev) / float64(prev) * 100
}

func (r *ProfileRun) ToJSON() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

func (r *ProfileRun) String() string {
	b, _ := r.ToJSON()
	return string(b)
}

func (r *ProfileRun) SummaryTable() string {
	var s string
	s += fmt.Sprintf("%-30s %8s %10s %10s %10s %10s\n", "SEGMENT", "COUNT", "MEAN", "P95", "P99", "MAX")
	s += fmt.Sprintf("%s\n", "─────────────────────────────────────────────────────────────────────────────")
	for _, seg := range []testbed.Segment{
		testbed.SegmentTotalE2E,
		testbed.SegmentQueueWait,
		testbed.SegmentE2EEncrypt,
		testbed.SegmentCoordinatorToProvider,
		testbed.SegmentProviderToBackend,
		testbed.SegmentTTFT,
		testbed.SegmentDecodeTPS,
		testbed.SegmentProviderToCoordinator,
		testbed.SegmentTotalE2E,
	} {
		if stats, ok := r.Aggregated[seg]; ok {
			s += fmt.Sprintf("%-30s %8d %10s %10s %10s %10s\n",
				seg, stats.Count,
				stats.Mean.Round(time.Millisecond),
				stats.P95.Round(time.Millisecond),
				stats.P99.Round(time.Millisecond),
				stats.Max.Round(time.Millisecond),
			)
		}
	}
	return s
}
