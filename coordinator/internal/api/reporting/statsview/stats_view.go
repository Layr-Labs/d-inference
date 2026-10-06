package statsview

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	refresher "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/refresher"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Stats struct {
	*refresher.Service
	store                 store.Store
	registry              *registry.Registry
	readCache             *readcache.Cache
	logger                *slog.Logger
	ddIncr                func(string, []string)
	statsRefresh          refresher.Entry
	statsGeographyRefresh refresher.Entry
}

func New(st store.Store, reg *registry.Registry, cache *readcache.Cache, logger *slog.Logger, incr func(string, []string), refresh *refresher.Service) *Stats {
	return &Stats{Service: refresh, store: st, registry: reg, readCache: cache, logger: logger, ddIncr: incr}
}

func (s *Stats) CachedStats() ([]byte, bool) {
	if body, ok := s.readCache.Get(StatsCacheKey); ok {
		return body, true
	}
	return s.GetCachedEntry(&s.statsRefresh, StatsCacheKey, s.computeStats)
}
