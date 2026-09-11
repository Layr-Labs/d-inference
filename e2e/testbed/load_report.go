package testbed

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// Keep both human-readable reports in the established coordinator segment order.
var loadReportSegments = []Segment{
	SegmentTotalE2E, SegmentParse, SegmentReserve, SegmentRoute,
	SegmentQueueWait, SegmentEncrypt, SegmentDispatch, SegmentCoordinatorToProvider,
	SegmentPreHandler, SegmentPreflight, SegmentRouteReserve, SegmentQueuePure,
	SegmentWriter, SegmentSocket, SegmentProviderAck, SegmentTTFT,
}

func (r *LoadResult) SummaryTable() string {
	var s strings.Builder

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

		for _, seg := range loadReportSegments {
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

type SegmentStatsView struct {
	Count  int
	Mean   time.Duration
	Median time.Duration
	P95    time.Duration
	P99    time.Duration
	Max    time.Duration
}

func (r *LoadResult) SummaryMarkdown() string {
	var s strings.Builder

	s.WriteString("| Metric | Value |\n|---|---|\n")
	s.WriteString(fmt.Sprintf("| Total Requests | %d |\n", r.TotalRequests))
	s.WriteString(fmt.Sprintf("| Success | %d |\n", r.SuccessCount))
	s.WriteString(fmt.Sprintf("| Errors | %d |\n", r.ErrorCount))
	s.WriteString(fmt.Sprintf("| Total Duration | %s |\n", r.TotalDuration.Round(time.Millisecond)))
	if r.SuccessCount > 0 {
		s.WriteString(fmt.Sprintf("| Throughput | %.1f req/s |\n", float64(r.SuccessCount)/r.TotalDuration.Seconds()))
	}

	if r.ProfileRun != nil && len(r.ProfileRun.SegmentTimings) > 0 {
		s.WriteString("\n### Latency Decomposition\n\n")
		s.WriteString("| Segment | Count | Mean | P50 | P95 | Max |\n|---|---|---|---|---|---|\n")

		for _, seg := range loadReportSegments {
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
		stats := computeStats(durations)
		out[seg] = &stats
	}
	return out
}

func computeStats(durations []time.Duration) SegmentStatsView {
	if len(durations) == 0 {
		return SegmentStatsView{}
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

	return SegmentStatsView{
		Count:  len(sorted),
		Mean:   mean,
		Median: median,
		P95:    sorted[p95Idx],
		P99:    sorted[len(sorted)*99/100],
		Max:    sorted[len(sorted)-1],
	}
}
