package registry_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func BenchmarkCacheMatchMaterialization(b *testing.B) {
	cells := []struct {
		name                                  string
		boundaries, providers, holders, tiers int
		dense, invalidDeep                    bool
	}{
		{"cold/208-boundaries", 208, 128, 0, 1, false, false},
		{"sparse/64-boundaries/4-holders", 64, 128, 4, 1, false, false},
		{"dense/208-boundaries/16-holders/2-tiers", 208, 128, 16, 2, true, false},
		{"dense/781-boundaries/16-holders/2-tiers", 781, 128, 16, 2, true, false},
		{"dense/208-boundaries/invalid-deep-epoch", 208, 128, 16, 2, true, true},
		{"churn/208-boundaries/distinct-epochs", 208, 128, 16, 2, true, false},
		{"churn/208-boundaries/distinct-pointers", 208, 128, 16, 2, true, false},
		{"churn/208-boundaries/distinct-measurements", 208, 128, 16, 2, true, false},
		{"churn/208-boundaries/128-providers", 208, 128, 128, 1, true, false},
		{"churn/208-boundaries/3328-distinct-providers", 208, 3328, 3328, 1, true, false},
	}
	for _, cell := range cells {
		b.Run(cell.name, func(b *testing.B) {
			var mutation cacheMatchMutation
			if cell.invalidDeep {
				mutation = func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
					if j >= cell.boundaries/2 {
						h.CacheEpoch = "stale-epoch"
					}
					return h
				}
			}
			if strings.Contains(cell.name, "distinct-") {
				mutation = func(f *cacheMatchFixture, h cacheHolder, j, i int, tier string) cacheHolder {
					switch {
					case strings.Contains(cell.name, "distinct-epochs"):
						h.CacheEpoch = fmt.Sprintf("epoch-%d", j)
					case strings.Contains(cell.name, "distinct-pointers"):
						h.Provider = &production.Provider{ID: h.ProviderID}
					case strings.Contains(cell.name, "distinct-measurements"):
						capability := f.capabilities[i]
						capability.CacheEpoch = fmt.Sprintf("measurement-%d", j)
						h.Measurement = cachetracker.NewMeasurement(120, f.now.Add(time.Hour), capability)
					}
					return h
				}
			}
			f := newCacheMatchFixture(cell.boundaries, cell.providers, cell.holders, cell.tiers, cell.dense, mutation)
			assertCacheMatchParity(b, f)
			expected, _ := f.referenceHints()
			for _, arm := range []string{"materialize_all", "compatibility_groups"} {
				b.Run(arm, func(b *testing.B) {
					b.ReportAllocs()
					b.ResetTimer()
					for i := 0; i < b.N; i++ {
						var result map[string]production.CacheRoutingHint
						if arm == "materialize_all" {
							result, _ = f.referenceHints()
						} else {
							result, _ = f.hints()
						}
						if len(result) != len(expected) {
							b.Fatal("hint cardinality changed")
						}
					}
				})
			}
		})
	}
}
