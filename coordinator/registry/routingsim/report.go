package routingsim

import (
	"fmt"
	"math"
	"sort"
	"strings"
)

// promptBucket is a half-open [Lo,Hi) prompt-token range used for reporting.
type promptBucket struct {
	Label string
	Lo    int
	Hi    int // exclusive; math.MaxInt for the open-ended top bucket
}

// ReportBuckets is the fixed prompt-size bucketing the harness reports on:
// [0-500, 500-750, 750-1000, 1000-2000, 2000-4000, 4000+].
var ReportBuckets = []promptBucket{
	{Label: "0-500", Lo: 0, Hi: 500},
	{Label: "500-750", Lo: 500, Hi: 750},
	{Label: "750-1000", Lo: 750, Hi: 1000},
	{Label: "1000-2000", Lo: 1000, Hi: 2000},
	{Label: "2000-4000", Lo: 2000, Hi: 4000},
	{Label: "4000+", Lo: 4000, Hi: math.MaxInt},
}

func bucketIndexFor(promptTokens int) int {
	for i, b := range ReportBuckets {
		if promptTokens >= b.Lo && promptTokens < b.Hi {
			return i
		}
	}
	return len(ReportBuckets) - 1
}

// BucketStats holds outcome counts and rates for one prompt-size bucket.
type BucketStats struct {
	Label        string
	Total        int
	Served       int
	MachineBusy  int
	TTFTTooSlow  int
	OtherRejects int // any non-served outcome that is not the two known reject codes
}

// AcceptRate is the fraction of arrivals in the bucket that were served.
func (b BucketStats) AcceptRate() float64 {
	if b.Total == 0 {
		return 0
	}
	return float64(b.Served) / float64(b.Total)
}

// RejectRate is 1 - AcceptRate.
func (b BucketStats) RejectRate() float64 {
	if b.Total == 0 {
		return 0
	}
	return float64(b.Total-b.Served) / float64(b.Total)
}

// TTFTRejectRate is the fraction rejected specifically as ttft_too_slow.
func (b BucketStats) TTFTRejectRate() float64 {
	if b.Total == 0 {
		return 0
	}
	return float64(b.TTFTTooSlow) / float64(b.Total)
}

// Report aggregates a simulation run: overall outcome counts plus per-bucket
// stats in ReportBuckets order.
type Report struct {
	Total       int
	Served      int
	MachineBusy int
	TTFTTooSlow int
	Buckets     []BucketStats
}

// Summarize aggregates per-arrival results into a Report.
func Summarize(results []Result) Report {
	buckets := make([]BucketStats, len(ReportBuckets))
	for i, b := range ReportBuckets {
		buckets[i].Label = b.Label
	}
	rep := Report{Buckets: buckets}
	for _, res := range results {
		rep.Total++
		bi := bucketIndexFor(res.Arrival.PromptTokens)
		b := &rep.Buckets[bi]
		b.Total++
		switch res.Outcome {
		case OutcomeServed:
			rep.Served++
			b.Served++
		case OutcomeMachineBusy:
			rep.MachineBusy++
			b.MachineBusy++
		case OutcomeTTFTTooSlow:
			rep.TTFTTooSlow++
			b.TTFTTooSlow++
		default:
			b.OtherRejects++
		}
	}
	return rep
}

// Bucket returns the stats for a bucket by label, or false if not found.
func (r Report) Bucket(label string) (BucketStats, bool) {
	for _, b := range r.Buckets {
		if b.Label == label {
			return b, true
		}
	}
	return BucketStats{}, false
}

// AcceptRate is the overall served fraction across the whole run.
func (r Report) AcceptRate() float64 {
	if r.Total == 0 {
		return 0
	}
	return float64(r.Served) / float64(r.Total)
}

// EstimatedCliff returns the smallest prompt size (scanned at 1-token
// granularity across the observed prompt range) at which served arrivals give
// way to ttft_too_slow, derived from the per-arrival results. It returns 0 when
// no transition is observed. Useful for logging where the cliff actually lands.
func EstimatedCliff(results []Result) int {
	sorted := append([]Result(nil), results...)
	sort.SliceStable(sorted, func(i, j int) bool {
		return sorted[i].Arrival.PromptTokens < sorted[j].Arrival.PromptTokens
	})
	lastServed := -1
	for _, res := range sorted {
		switch res.Outcome {
		case OutcomeServed:
			lastServed = res.Arrival.PromptTokens
		case OutcomeTTFTTooSlow:
			if lastServed >= 0 && res.Arrival.PromptTokens > lastServed {
				return res.Arrival.PromptTokens
			}
		}
	}
	return 0
}

// String renders a compact human-readable table of the report.
func (r Report) String() string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "routingsim report: %d arrivals  served=%d (%.1f%%)  machine_busy=%d  ttft_too_slow=%d\n",
		r.Total, r.Served, r.AcceptRate()*100, r.MachineBusy, r.TTFTTooSlow)
	fmt.Fprintf(&sb, "%-12s %7s %8s %8s %12s %12s\n", "bucket", "total", "served", "accept%", "machine_busy", "ttft_slow")
	for _, b := range r.Buckets {
		fmt.Fprintf(&sb, "%-12s %7d %8d %7.1f%% %12d %12d\n",
			b.Label, b.Total, b.Served, b.AcceptRate()*100, b.MachineBusy, b.TTFTTooSlow)
	}
	return sb.String()
}
