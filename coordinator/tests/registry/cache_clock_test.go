package registry_test

import (
	"sync/atomic"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheClockRetainedAcrossConfigurationGenerations(t *testing.T) {
	var reads atomic.Int64
	clock := func() time.Time {
		reads.Add(1)
		return time.Unix(1000, 0)
	}
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		Cache: production.CacheDependencies{Now: clock},
	})
	if reads.Load() != 0 {
		t.Fatal("cache construction called the receipt clock before publication")
	}
	for generation := int64(1); generation <= 3; generation++ {
		if holders, attempts := r.CacheRoutingStateCounts(); holders != 0 || attempts != 0 {
			t.Fatalf("generation %d: unexpected empty-registry state holders=%d attempts=%d", generation, holders, attempts)
		}
		if got := reads.Load(); got != generation {
			t.Fatalf("generation %d did not retain the constructor clock: reads=%d", generation, got)
		}
		if err := r.ConfigureCacheRouting(production.CacheRoutingConfig{
			Mode: production.CacheRoutingOff, ActivationPct: 100, TTL: time.Minute, MaxHolders: 4,
		}); err != nil {
			t.Fatal(err)
		}
	}
}
