package registry

import "log/slog"

// warnCacheRoutingTTL reports a holder TTL beyond what the indexes are sized
// for. It is a warning only: the coordinator still starts and routes.
func (r *Registry) warnCacheRoutingTTL(cfg CacheRoutingConfig) {
	if r.logger == nil || cfg.Mode == CacheRoutingOff || cfg.TTL <= cacheRoutingSizingTTL {
		return
	}
	r.logger.Warn("cache routing ttl exceeds the window the indexes are sized for: "+
		"the observed-demand index turns over before the ttl and reports repeated prefixes as novel, "+
		"and providers have already expired the cache files the older holders point at",
		slog.Duration("ttl", cfg.TTL),
		slog.Duration("sized_for", cacheRoutingSizingTTL),
		slog.Int("demand_entries", cacheDemandMaxEntries),
		slog.Int("holder_entries", cacheRoutingMaxEntries))
}
