package registry_test

import (
	"fmt"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func BenchmarkColdKVCapacityForecast(b *testing.B) {
	for _, size := range []int{64, 1024} {
		for _, cold := range []bool{false, true} {
			b.Run(fmt.Sprintf("providers=%d/cold=%t", size, cold), func(b *testing.B) {
				r := production.New(testLogger())
				model := coldKVModelInfo(coldKVModel, "a")
				r.SetModelCatalog([]production.CatalogEntry{{ID: model.ID, WeightHash: model.WeightHash, SizeGB: 28, MinRAMGB: 48}})
				for i := 0; i < size; i++ {
					p := coldKVProvider(b, r, fmt.Sprintf("provider-%d", i), 48, model)
					if cold && i%2 == 0 {
						coldKVHeartbeat(b, r, p, 1)
					} else {
						coldKVHeartbeat(b, r, p, 1, coldKVSlot(model, 20_480))
					}
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					candidates, _, _ := r.QuickCapacityCheck(model.ID, 500, 256, production.RequestTraits{})
					if candidates != size {
						b.Fatalf("candidates=%d, want %d", candidates, size)
					}
				}
			})
		}
	}
}

func BenchmarkFleetSampleColdKVForecast(b *testing.B) {
	for _, size := range []int{64, 1024} {
		for _, pending := range []bool{false, true} {
			b.Run(fmt.Sprintf("providers=%d/pending=%t", size, pending), func(b *testing.B) {
				r := production.New(testLogger())
				a := coldKVModelInfo("test/sampled-a", "a")
				other := coldKVModelInfo("test/sampled-b", "d")
				r.SetModelCatalog([]production.CatalogEntry{
					{ID: a.ID, WeightHash: a.WeightHash, SizeGB: 28, MinRAMGB: 48},
					{ID: other.ID, WeightHash: other.WeightHash, SizeGB: 28, MinRAMGB: 48},
				})
				for i := 0; i < size; i++ {
					p := coldKVProvider(b, r, fmt.Sprintf("provider-%d", i), 64, a, other)
					resident, cold := a, other
					if i%2 == 0 {
						resident, cold = other, a
					}
					coldKVHeartbeat(b, r, p, 1, coldKVSlot(resident, 20_480))
					if pending {
						p.AddPending(&production.PendingRequest{RequestID: fmt.Sprintf("pending-%d", i), Model: cold.ID, RequestedMaxTokens: 20_000})
					}
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					if rows := r.FleetSample(time.Now()); len(rows) != size {
						b.Fatalf("rows=%d, want %d", len(rows), size)
					}
				}
			})
		}
	}
}
