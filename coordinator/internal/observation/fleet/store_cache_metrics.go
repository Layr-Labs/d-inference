package fleet

import "github.com/eigeninference/d-inference/coordinator/store"

// storeCacheStatsProvider is implemented by store.CachedStore (the production
// store wrapper, see cmd/coordinator/main.go). Discovered by assertion so the
// owner keeps depending only on store.Store.
type storeCacheStatsProvider interface {
	Stats() store.CacheStats
}

// emitStoreCacheGauges publishes the read-through store cache counters as
// DogStatsD gauges, tagged by domain (users / models). The hit ratio is the
// number that proves the cache is removing the per-request user and
// model-registry round trips; without it the cache is dark in production.
// Called from StartDDGaugeLoop every 15s; a no-op when the store is not
// wrapped (tests, bare stores) or Datadog is not configured.
func EmitStoreCacheGauges(st store.Store, gauge func(string, float64, []string)) {
	provider, ok := st.(storeCacheStatsProvider)
	if !ok {
		return
	}
	stats := provider.Stats()
	emitStoreCacheDomainGauges(gauge, "users", stats.Users)
	emitStoreCacheDomainGauges(gauge, "models", stats.Models)
}

func emitStoreCacheDomainGauges(gauge func(string, float64, []string), domain string, c store.CacheCounters) {
	tags := []string{"domain:" + domain}
	gauge("store.cache.hits", float64(c.Hits), tags)
	gauge("store.cache.misses", float64(c.Misses), tags)
	gauge("store.cache.negative_hits", float64(c.NegativeHits), tags)
	gauge("store.cache.evictions", float64(c.Evictions), tags)
	gauge("store.cache.invalidations", float64(c.Invalidations), tags)
	gauge("store.cache.entries", float64(c.Entries), tags)
}
