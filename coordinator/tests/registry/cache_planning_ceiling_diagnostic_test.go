package registry_test

import (
	"fmt"
	"testing"
	"time"

	cacheactivation "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
)

// Production admission mechanism under fixed synthetic arrival rates. This is
// an eligibility ceiling, deliberately not labelled cache-hit throughput.
func TestDiagnosticFortyQPSPlanningCeiling(t *testing.T) {
	for _, qps := range []int{20, 40, 80, 160} {
		t.Run(fmt.Sprintf("arrivals_%d_qps", qps), func(t *testing.T) {
			gate := cacheactivation.New(100, 40)
			start := time.Unix(1700000000, 0)
			requests, admitted := 60*qps, 0
			for i := 0; i < requests; i++ {
				now := start.Add(time.Duration(i) * (time.Second / time.Duration(qps)))
				if gate.Allow([]byte("synthetic-cohort-boundary"), now) == cacheactivation.Admitted {
					admitted++
				}
			}
			status := gate.Snapshot()
			if status.Admitted+status.RateLimited != uint64(requests) || admitted == 0 {
				t.Fatal("inconsistent admission")
			}
			if qps <= 40 && admitted != requests {
				t.Fatal("unexpected throttle below configured rate")
			}
			if qps > 40 && (admitted > 2440 || admitted < 2390) {
				t.Fatal("refill/burst bound changed")
			}
			t.Logf("requests=%d admitted=%d rate_limited=%d planning_eligibility_percent=%.3f; not a cache-hit measurement", requests, admitted, status.RateLimited, 100*float64(admitted)/float64(requests))
		})
	}
}
