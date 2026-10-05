package registry_test

import (
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func settledHeapBytes() uint64 {
	runtime.GC()
	runtime.GC()
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	return stats.HeapAlloc
}

// Run once without the race detector to measure the settled heap of a full index.
func BenchmarkCacheDemandMemory(b *testing.B) {
	b.Run(fmt.Sprintf("entries=%d", cachedemand.MaxEntries), func(b *testing.B) {
		for i := 0; i < b.N; i++ {
			demand := newDemandFixture(cachedemand.MaxEntries, cachedemand.SizingTTL)
			generation := &cacheplan.Generation{}
			routeKey := []byte("0123456789abcdef0123456789abcdef")
			now := time.Unix(1_700_000_000, 0)
			before := settledHeapBytes()
			for index := 0; index < cachedemand.MaxEntries; index++ {
				plan := demandPlanValue(protocol.PrefixCacheAnchor{
					TokenCount: int(promptcontract.BlockSize), ChainHash: fmt.Sprintf("%064x", index+1),
				})
				plan = bindDemandPlan(generation, plan)
				plan.ObserveRouteDemand(generation, demand.tracker, routeKey, now)
			}
			after := settledHeapBytes()
			if entries := demand.index.Len(); entries != cachedemand.MaxEntries {
				b.Fatalf("entries=%d", entries)
			}
			b.ReportMetric(float64(after-before)/float64(cachedemand.MaxEntries), "B/entry")
			b.ReportMetric(float64(after-before)/(1<<20), "MiB/full-index")
			runtime.KeepAlive(demand)
			runtime.KeepAlive(generation)
		}
	})
}
