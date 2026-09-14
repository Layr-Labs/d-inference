package registry

import (
	"fmt"
	"testing"
	"time"
)

// Compare the same reservation/release workload under all modes. The ordinary
// score prefers slow isolated prefill on half the fleet, so prefer mode must
// exercise actual selection, not merely compute estimates for the same winner.
func BenchmarkFirstContentRouting(b *testing.B) {
	benchmarkFirstContentRouting(b, false)
}

func BenchmarkFirstContentRoutingWithPlan(b *testing.B) {
	benchmarkFirstContentRouting(b, true)
}

func benchmarkFirstContentRouting(b *testing.B, withPlan bool) {
	for _, count := range []int{100, 500} {
		for _, mode := range []string{FirstContentRoutingOff, FirstContentRoutingShadow, FirstContentRoutingPrefer} {
			b.Run(fmt.Sprintf("providers=%d/%s", count, mode), func(b *testing.B) {
				reg := New(testLogger())
				if err := reg.ConfigureFirstContentRouting(mode); err != nil {
					b.Fatal(err)
				}
				providers := make([]*Provider, 0, count)
				for i := range count {
					observed, isolated := 4_000.0, 100.0
					if i%2 == 1 {
						observed, isolated = 500, 1_800
					}
					p := firstContentTestProvider(b, reg, fmt.Sprintf("bench-first-content-%04d", i), observed, isolated)
					providers = append(providers, p)
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := range b.N {
					if i%1_024 == 0 {
						// Heartbeat updates are outside the measurement, keeping
						// every calibration run on the same fresh-evidence path.
						b.StopTimer()
						now := time.Now()
						for _, p := range providers {
							p.mu.Lock()
							p.LastHeartbeat = now
							p.capacitySamplesAt = now
							p.mu.Unlock()
						}
						b.StartTimer()
					}
					pr := firstContentTestRequest()
					var p *Provider
					if withPlan {
						var plan *DispatchPlan
						p, _, plan = reg.ReserveProviderWithPlan(firstContentTestModel, pr)
						if plan == nil || plan.Remaining() > dispatchPlanMaxAlternates {
							b.Fatal("benchmark lost bounded dispatch plan")
						}
					} else {
						p, _ = reg.ReserveProviderEx(firstContentTestModel, pr)
					}
					if p == nil {
						b.Fatal("reservation failed")
					}
					wantFeasible := mode == FirstContentRoutingPrefer
					if selectedFeasible := (p.ID[len(p.ID)-1]-'0')%2 == 1; selectedFeasible != wantFeasible {
						b.Fatal("benchmark left its intended selection path")
					}
					p.RemovePending(pr.RequestID)
				}
			})
		}
	}
}
