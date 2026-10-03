package observation

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
func (s *Owner) emitStoreCacheGauges() {
	if s.Datadog() == nil {
		return
	}
	provider, ok := s.store.(storeCacheStatsProvider)
	if !ok {
		return
	}
	stats := provider.Stats()
	s.emitStoreCacheDomainGauges("users", stats.Users)
	s.emitStoreCacheDomainGauges("models", stats.Models)
}

func (s *Owner) emitStoreCacheDomainGauges(domain string, c store.CacheCounters) {
	tags := []string{"domain:" + domain}
	s.Gauge("store.cache.hits", float64(c.Hits), tags)
	s.Gauge("store.cache.misses", float64(c.Misses), tags)
	s.Gauge("store.cache.negative_hits", float64(c.NegativeHits), tags)
	s.Gauge("store.cache.evictions", float64(c.Evictions), tags)
	s.Gauge("store.cache.invalidations", float64(c.Invalidations), tags)
	s.Gauge("store.cache.entries", float64(c.Entries), tags)
}
