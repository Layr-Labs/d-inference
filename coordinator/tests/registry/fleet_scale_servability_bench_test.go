package registry_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// BenchmarkFleetPredictServable is the structural prompt-size gate: one walk
// per request, per-provider snapshot + structural budget.
func BenchmarkFleetPredictServable(b *testing.B) {
	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	model := f.models[0]
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		verdict := f.reg.PredictServable(model, 600, 600, 512, 128_000, production.RequestTraits{}, false)
		if !verdict.Servable || verdict.ProviderCount == 0 {
			b.Fatalf("fixture is not servable: %+v", verdict)
		}
	}
}
