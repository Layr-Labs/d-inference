package registry_test

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A rare widely-advertised model must not inflate the reset cost of the same
// registry's common narrower scans. The fleet uses real model-index updates.
func buildSkewedBenchFleet(tb testing.TB) *benchFleet {
	f := buildBenchFleet(tb, 6000, 15)
	for _, id := range f.ids {
		f.reg.MergeProviderModels(id, []protocol.ModelInfo{{ID: f.models[0], ModelType: "chat", Quantization: "4bit"}})
	}
	return f
}

func BenchmarkReservationSkewedModels(b *testing.B) {
	for _, largeEvery := range []int{1, 20} {
		b.Run(fmt.Sprintf("largeEvery=%d", largeEvery), func(b *testing.B) {
			f := buildSkewedBenchFleet(b)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				model := f.models[14]
				if i%largeEvery == 0 {
					model = f.models[0]
				}
				pr := benchPendingRequest(model, i)
				p, _ := f.reg.ReserveProviderEx(model, pr)
				if p == nil || p.RemovePending(pr.RequestID) != pr {
					b.Fatal("skewed fleet has no provider or lost its debit")
				}
			}
		})
	}
}

func TestReservationSkewedFleetFixture(t *testing.T) {
	f := buildSkewedBenchFleet(t)
	for i, model := range []string{f.models[0], f.models[14]} {
		pr := benchPendingRequest(model, i)
		p, decision := f.reg.ReserveProviderEx(model, pr)
		if p == nil || p.RemovePending(pr.RequestID) != pr {
			t.Fatal("skewed fleet did not reserve/remove")
		}
		if i == 0 && decision.Scanned != 6000 {
			t.Fatalf("large scan=%d want6000", decision.Scanned)
		}
		if i == 1 && decision.Scanned != 1000 {
			t.Fatalf("narrow scan=%d want1000", decision.Scanned)
		}
	}
}
