package api

import (
	"fmt"
	"math"
	"slices"
	"strings"
	"testing"
)

func TestHistogramUpperBoundsIncludeExactValues(t *testing.T) {
	buckets := DefaultBuckets()
	for _, boundary := range buckets {
		for _, sample := range []float64{math.Nextafter(boundary, math.Inf(-1)), boundary, math.Nextafter(boundary, math.Inf(1))} {
			t.Run(fmt.Sprintf("bound_%g_sample_%.17g", boundary, sample), func(t *testing.T) {
				h := NewHistogram(buckets)
				h.Observe(sample)
				snap := h.Snapshot()
				want := make([]int64, len(buckets)+1)
				for i, upper := range buckets {
					if sample <= upper {
						want[i] = 1
					}
				}
				want[len(buckets)] = 1
				if !slices.Equal(snap.Counts, want) {
					t.Fatalf("cumulative counts = %v, want %v", snap.Counts, want)
				}
				if snap.Count != 1 || snap.Sum != sample {
					t.Fatalf("sample accounting changed: %+v", snap)
				}
			})
		}
	}
}

func TestPromHistogramIncludesBoundaryInMatchingBucket(t *testing.T) {
	m := NewMetrics()
	m.ObserveHistogram("request_ms", 5)
	m.ObserveHistogram("request_ms", 10)
	text := m.Snapshot().RenderProm()
	for _, line := range []string{
		`request_ms_bucket{le="5"} 1`,
		`request_ms_bucket{le="10"} 2`,
		`request_ms_bucket{le="+Inf"} 2`,
		`request_ms_count 2`,
		`request_ms_sum 15`,
	} {
		if !strings.Contains("\n"+text, "\n"+line+"\n") {
			t.Fatalf("missing sample %q in export:\n%s", line, text)
		}
	}
}
