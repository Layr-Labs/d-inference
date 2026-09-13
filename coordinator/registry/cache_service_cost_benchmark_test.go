package registry

import "testing"

// Exercise the same snapshot, currency check and provider locking in both
// revisions. Candidate copies keep each iteration independent of prior scores.
func BenchmarkCacheServiceCost(b *testing.B) {
	for _, scenario := range []string{"useful_hit", "expensive_stage", "stale_hint"} {
		b.Run(scenario, func(b *testing.B) {
			r, original, hint := serviceCostFixture(1000, 0, 0)
			if scenario == "expensive_stage" {
				hint.StageMs = 5000
			} else if scenario == "stale_hint" {
				original.provider.prefixCacheRevision++
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				candidate := *original
				applyServiceHint(r, &candidate, hint)
			}
		})
	}
}
