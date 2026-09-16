package metrics

// StoreMetrics covers the persistence layer's latency and its read caches. The
// two latency series are deliberately one metric each with an `op` tag rather
// than a metric per operation: the question an operator has is "is the store
// slow", and the breakdown is a tag away.
type StoreMetrics struct {
	// DebitLatencyMs and CreditLatencyMs measure the store round trip for a
	// money movement, tagged by the operation that asked for it.
	DebitLatencyMs  *Distribution
	CreditLatencyMs *Distribution

	// The cache counters are cumulative totals read off the store's wrapper, so
	// they are pushed as gauges of the total rather than as deltas: the wrapper
	// owns the count, this only reports it. `domain` is the cached entity
	// (`users`, `models`).
	CacheHits          *Gauge
	CacheMisses        *Gauge
	CacheNegativeHits  *Gauge
	CacheEvictions     *Gauge
	CacheInvalidations *Gauge
	CacheEntries       *Gauge
}

func newStoreMetrics(m *Metrics) *StoreMetrics {
	return &StoreMetrics{
		DebitLatencyMs: m.distribution("store.debit.latency_ms",
			"Store round trip for a debit, by operation",
			"op"),
		CreditLatencyMs: m.distribution("store.credit.latency_ms",
			"Store round trip for a credit, by operation",
			"op"),

		CacheHits: m.gauge("store.cache.hits",
			"Cumulative read-cache hits reported by the store wrapper",
			"domain"),
		CacheMisses: m.gauge("store.cache.misses",
			"Cumulative read-cache misses",
			"domain"),
		CacheNegativeHits: m.gauge("store.cache.negative_hits",
			"Cumulative hits on a cached not-found",
			"domain"),
		CacheEvictions: m.gauge("store.cache.evictions",
			"Cumulative entries evicted for capacity",
			"domain"),
		CacheInvalidations: m.gauge("store.cache.invalidations",
			"Cumulative explicit invalidations after a write",
			"domain"),
		CacheEntries: m.gauge("store.cache.entries",
			"Entries resident in the read cache now",
			"domain"),
	}
}
