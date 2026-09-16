package registry

import (
	"fmt"
	"testing"
)

// Exercise retained plan construction through the complete reservation path,
// using the same mixed-health fleet and cleanup as the existing scan benchmark.
func BenchmarkReserveProviderWithPlan_350x2(b *testing.B) {
	reg := buildReserveBenchFleet(b)
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		model, pr := reserveBenchRequest(i)
		provider, _, plan := reg.ReserveProviderWithPlan(model, pr)
		if provider == nil || plan == nil || plan.Len() == 0 {
			b.Fatal("no provider or retained plan selected")
		}
		provider.RemovePending(pr.RequestID)
	}
}

var dispatchPlanBenchmarkResult *DispatchPlan

// Keep construction's allocation behavior visible across the owner boundary.
// Every input is already a scan candidate; benchmark setup does no timed work.
func BenchmarkDispatchPlanRetention(b *testing.B) {
	for _, size := range []int{8, 64, 256} {
		b.Run(fmt.Sprint(size), func(b *testing.B) {
			scan := candidateScan{candidateCount: size}
			for i := 0; i < size; i++ {
				scan.pool = append(scan.pool, &routingCandidate{provider: &Provider{ID: fmt.Sprint(i)}, costMs: float64(size - i)})
			}
			winner := scan.pool[size-1]
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				dispatchPlanBenchmarkResult = newDispatchPlan("model", scan, winner)
			}
		})
	}
}
