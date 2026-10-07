package registry_test

import (
	"fmt"
	"testing"

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
