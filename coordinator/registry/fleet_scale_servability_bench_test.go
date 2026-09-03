package registry

// Fleet-scale benchmark for the servability gate — the THIRD full-fleet walk
// every public request pays (api/servability_gate.go → PredictServable) before
// the QuickCapacityCheck preflight and the reservation scan. Shares the
// fixture in fleet_scale_bench_test.go so all three walks are measured on the
// same 1,260-provider / 15-model fleet:
//
//	go test ./registry/ -run '^$' -bench 'Fleet' -benchmem

import "testing"

// BenchmarkFleetPredictServable is the structural prompt-size gate: one walk
// per request, per-provider snapshot + structural budget.
func BenchmarkFleetPredictServable(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	model := f.models[0]
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		verdict := f.reg.PredictServable(model, 600, 600, 512, 128_000, RequestTraits{}, false)
		if !verdict.Servable || verdict.ProviderCount == 0 {
			b.Fatalf("fixture is not servable: %+v", verdict)
		}
	}
}
