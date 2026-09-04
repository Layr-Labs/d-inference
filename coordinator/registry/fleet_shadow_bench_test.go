package registry

import (
	"fmt"
	"testing"
)

// BenchmarkFleetReserveProviderExShadow is BenchmarkFleetReserveProviderEx
// with the TTFT shadow evaluator on (prod: EIGENINFERENCE_TTFT_ADMISSION_MODE
// =shadow) and every winner herded: each provider advertising the model
// carries one in-flight request for it, so snapshotOccupancy(winner) > 0 on
// every reservation and the evaluator's busy-winner path runs each op. The
// walks/op metric (FleetWalkCount delta per reservation) is the observable:
// 2 while the evaluator re-walked the fleet after the commit, 1 now.
//
//	go test ./registry/ -run '^$' -bench 'FleetReserveProviderExShadow' -benchmem
func BenchmarkFleetReserveProviderExShadow(b *testing.B) {
	prevMode := TTFTAdmissionModeValue()
	SetTTFTAdmissionMode(TTFTAdmissionShadow)
	b.Cleanup(func() { SetTTFTAdmissionMode(prevMode) })

	f := buildBenchFleet(b, benchFleetProviders, benchFleetModels)
	model := f.models[0]
	for _, id := range f.ids {
		p := f.reg.GetProvider(id)
		if p == nil {
			continue
		}
		p.AddPending(&PendingRequest{
			RequestID:             fmt.Sprintf("%s-herd", id),
			Model:                 model,
			EstimatedPromptTokens: 600,
			RequestedMaxTokens:    512,
		})
	}
	walksBefore := f.reg.FleetWalkCount()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		pr := benchPendingRequest(model, i)
		p, decision := f.reg.ReserveProviderEx(model, pr)
		if p == nil {
			b.Fatal("no provider reserved")
		}
		if !decision.ShadowEvaluated || decision.ShadowOccupancy == 0 {
			b.Fatalf("winner not herded under shadow mode: %+v", decision)
		}
		p.RemovePending(pr.RequestID)
	}
	b.StopTimer()
	b.ReportMetric(float64(f.reg.FleetWalkCount()-walksBefore)/float64(b.N), "walks/op")
}
