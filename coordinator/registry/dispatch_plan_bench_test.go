package registry

import "testing"

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
