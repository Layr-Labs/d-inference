package testbed

import (
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"
)

type LoadResult struct {
	TotalRequests     int
	ExpectedSuccesses int
	MinimumSuccesses  int
	SuccessCount      int
	ErrorCount        int
	TotalDuration     time.Duration
	ProfileRun        *ProfileRun
	RequestResults    []RequestResult
	Failures          []RequestFailure
	ModelCohorts      map[string]CohortStats
	UserCohorts       map[int]CohortStats
}

type RequestResult struct {
	Index      int
	StatusCode int
	Error      error
	Duration   time.Duration
	TTFT       time.Duration
	UserIndex  int
	ModelID    string

	ParseUs      int64
	ReserveUs    int64
	MediaFetchUs int64
	RouteUs      int64
	QueueUs      int64
	EncryptUs    int64
	DispatchUs   int64
	ProviderUs   int64
}

type RequestFailure struct {
	Index     int
	UserIndex int
	ModelID   string
	Err       error
}

func (f RequestFailure) Error() string {
	return fmt.Sprintf("request %d (model=%q user=%d): %v", f.Index, f.ModelID, f.UserIndex, f.Err)
}

func (f RequestFailure) Unwrap() error {
	return f.Err
}

type CohortStats struct {
	TotalRequests int
	SuccessCount  int
	ErrorCount    int
	Failures      []RequestFailure
}

type ProfileRun struct {
	SegmentTimings map[Segment][]time.Duration
	TTFTs          []time.Duration
}

type SegmentStatsView struct {
	Count  int
	Mean   time.Duration
	Median time.Duration
	P95    time.Duration
	P99    time.Duration
	Max    time.Duration
}

func (r *LoadResult) aggregate(requestResults []RequestResult, totalDuration time.Duration) {
	segmentTimings := make(map[Segment][]time.Duration)
	for _, result := range requestResults {
		if result.Error != nil || result.StatusCode != http.StatusOK {
			r.ErrorCount++
			continue
		}
		r.SuccessCount++
		segmentTimings[SegmentTotalE2E] = append(segmentTimings[SegmentTotalE2E], result.Duration)
		appendTimingSegments(segmentTimings, result)
		if result.TTFT > 0 {
			segmentTimings[SegmentTTFT] = append(segmentTimings[SegmentTTFT], result.TTFT)
		}
	}

	r.TotalDuration = totalDuration
	r.RequestResults = requestResults
	r.ProfileRun = &ProfileRun{
		SegmentTimings: segmentTimings,
		TTFTs:          append([]time.Duration(nil), segmentTimings[SegmentTTFT]...),
	}
	r.Failures, r.ModelCohorts, r.UserCohorts = buildCohorts(requestResults)
}

func (r *LoadResult) thresholdError() error {
	if r.SuccessCount >= r.MinimumSuccesses {
		return nil
	}

	errs := make([]error, len(r.Failures))
	for i := range r.Failures {
		errs[i] = r.Failures[i]
	}
	thresholdErr := fmt.Errorf(
		"load success threshold unmet: got %d successes, expected %d, minimum %d",
		r.SuccessCount,
		r.ExpectedSuccesses,
		r.MinimumSuccesses,
	)
	if requestErr := errors.Join(errs...); requestErr != nil {
		thresholdErr = errors.Join(thresholdErr, requestErr)
	}
	return thresholdErr
}

func appendTimingSegments(segmentTimings map[Segment][]time.Duration, result RequestResult) {
	appendTimingSegment(segmentTimings, SegmentParse, result.ParseUs)
	appendTimingSegment(segmentTimings, SegmentReserve, result.ReserveUs)
	appendTimingSegment(segmentTimings, SegmentRoute, result.RouteUs)
	appendTimingSegment(segmentTimings, SegmentQueueWait, result.QueueUs)
	appendTimingSegment(segmentTimings, SegmentEncrypt, result.EncryptUs)
	appendTimingSegment(segmentTimings, SegmentDispatch, result.DispatchUs)
	appendTimingSegment(segmentTimings, SegmentCoordinatorToProvider, result.ProviderUs)
}

func appendTimingSegment(segmentTimings map[Segment][]time.Duration, segment Segment, micros int64) {
	if micros > 0 {
		segmentTimings[segment] = append(segmentTimings[segment], time.Duration(micros)*time.Microsecond)
	}
}

func buildCohorts(results []RequestResult) ([]RequestFailure, map[string]CohortStats, map[int]CohortStats) {
	failures := make([]RequestFailure, 0)
	models := make(map[string]CohortStats)
	users := make(map[int]CohortStats)
	for _, result := range results {
		modelStats := models[result.ModelID]
		userStats := users[result.UserIndex]
		modelStats.TotalRequests++
		userStats.TotalRequests++

		if result.Error == nil && result.StatusCode == http.StatusOK {
			modelStats.SuccessCount++
			userStats.SuccessCount++
		} else {
			failure := RequestFailure{
				Index:     result.Index,
				UserIndex: result.UserIndex,
				ModelID:   result.ModelID,
				Err:       result.Error,
			}
			failures = append(failures, failure)
			modelStats.ErrorCount++
			userStats.ErrorCount++
			modelStats.Failures = append(modelStats.Failures, failure)
			userStats.Failures = append(userStats.Failures, failure)
		}
		models[result.ModelID] = modelStats
		users[result.UserIndex] = userStats
	}
	return failures, models, users
}

func (r *LoadResult) SummaryTable() string {
	var s strings.Builder

	s.WriteString(fmt.Sprintf("%-20s %d\n", "Expected Success:", r.ExpectedSuccesses))
	s.WriteString(fmt.Sprintf("%-20s %d\n", "Minimum Success:", r.MinimumSuccesses))
	s.WriteString(fmt.Sprintf("%-20s %d\n", "Total Requests:", r.TotalRequests))
	s.WriteString(fmt.Sprintf("%-20s %d\n", "Success:", r.SuccessCount))
	s.WriteString(fmt.Sprintf("%-20s %d\n", "Errors:", r.ErrorCount))
	s.WriteString(fmt.Sprintf("%-20s %s\n", "Total Duration:", r.TotalDuration.Round(time.Millisecond)))
	if r.SuccessCount > 0 {
		s.WriteString(fmt.Sprintf("%-20s %.1f req/s\n", "Throughput:", float64(r.SuccessCount)/r.TotalDuration.Seconds()))
	}

	if r.ProfileRun != nil && len(r.ProfileRun.SegmentTimings) > 0 {
		s.WriteString("\n")
		s.WriteString(fmt.Sprintf("%-30s %8s %8s %8s %8s %8s\n", "SEGMENT", "COUNT", "MEAN", "P50", "P95", "MAX"))
		s.WriteString("─────────────────────────────────────────────────────────────────────\n")

		for _, seg := range []Segment{
			SegmentTotalE2E,
			SegmentParse,
			SegmentReserve,
			SegmentRoute,
			SegmentQueueWait,
			SegmentEncrypt,
			SegmentDispatch,
			SegmentCoordinatorToProvider,
			SegmentTTFT,
		} {
			durations, ok := r.ProfileRun.SegmentTimings[seg]
			if !ok || len(durations) == 0 {
				continue
			}
			stats := computeStats(durations)
			precision := time.Millisecond
			if stats.Max < time.Millisecond {
				precision = time.Microsecond
			}
			s.WriteString(fmt.Sprintf("%-30s %8d %8s %8s %8s %8s\n",
				seg, stats.Count,
				stats.Mean.Round(precision),
				stats.Median.Round(precision),
				stats.P95.Round(precision),
				stats.Max.Round(precision),
			))
		}
	}

	return s.String()
}

func (r *LoadResult) SummaryMarkdown() string {
	var s strings.Builder

	s.WriteString(fmt.Sprintf("| Metric | Value |\n|---|---|\n"))
	s.WriteString(fmt.Sprintf("| Total Requests | %d |\n", r.TotalRequests))
	s.WriteString(fmt.Sprintf("| Expected Success | %d |\n", r.ExpectedSuccesses))
	s.WriteString(fmt.Sprintf("| Minimum Success | %d |\n", r.MinimumSuccesses))
	s.WriteString(fmt.Sprintf("| Success | %d |\n", r.SuccessCount))
	s.WriteString(fmt.Sprintf("| Errors | %d |\n", r.ErrorCount))
	s.WriteString(fmt.Sprintf("| Total Duration | %s |\n", r.TotalDuration.Round(time.Millisecond)))
	if r.SuccessCount > 0 {
		s.WriteString(fmt.Sprintf("| Throughput | %.1f req/s |\n", float64(r.SuccessCount)/r.TotalDuration.Seconds()))
	}

	if r.ProfileRun != nil && len(r.ProfileRun.SegmentTimings) > 0 {
		s.WriteString("\n### Latency Decomposition\n\n")
		s.WriteString("| Segment | Count | Mean | P50 | P95 | Max |\n|---|---|---|---|---|---|\n")

		for _, seg := range []Segment{
			SegmentTotalE2E,
			SegmentParse,
			SegmentReserve,
			SegmentRoute,
			SegmentQueueWait,
			SegmentEncrypt,
			SegmentDispatch,
			SegmentCoordinatorToProvider,
			SegmentTTFT,
		} {
			durations, ok := r.ProfileRun.SegmentTimings[seg]
			if !ok || len(durations) == 0 {
				continue
			}
			stats := computeStats(durations)
			precision := time.Millisecond
			if stats.Max < time.Millisecond {
				precision = time.Microsecond
			}
			s.WriteString(fmt.Sprintf("| %s | %d | %s | %s | %s | %s |\n",
				seg, stats.Count,
				stats.Mean.Round(precision),
				stats.Median.Round(precision),
				stats.P95.Round(precision),
				stats.Max.Round(precision),
			))
		}
	}

	return s.String()
}

func (r *LoadResult) SegmentStatsMap() map[Segment]*SegmentStatsView {
	if r.ProfileRun == nil {
		return nil
	}
	out := make(map[Segment]*SegmentStatsView, len(r.ProfileRun.SegmentTimings))
	for seg, durations := range r.ProfileRun.SegmentTimings {
		if len(durations) == 0 {
			continue
		}
		sorted := make([]time.Duration, len(durations))
		copy(sorted, durations)
		sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

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
		p99Idx := len(sorted) * 99 / 100
		if p99Idx >= len(sorted) {
			p99Idx = len(sorted) - 1
		}

		out[seg] = &SegmentStatsView{
			Count:  len(sorted),
			Mean:   mean,
			Median: median,
			P95:    sorted[p95Idx],
			P99:    sorted[p99Idx],
			Max:    sorted[len(sorted)-1],
		}
	}
	return out
}

type simpleStats struct {
	Count  int
	Mean   time.Duration
	Median time.Duration
	P95    time.Duration
	Max    time.Duration
}

func computeStats(durations []time.Duration) simpleStats {
	if len(durations) == 0 {
		return simpleStats{}
	}

	sorted := make([]time.Duration, len(durations))
	copy(sorted, durations)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })

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
