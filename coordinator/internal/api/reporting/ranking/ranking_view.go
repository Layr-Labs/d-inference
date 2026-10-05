package ranking

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/sync/singleflight"
)

type Ranking struct {
	store              store.Store
	readCache          *readcache.Cache
	logger             *slog.Logger
	ddIncr             func(string, []string)
	leaderboardFlights singleflight.Group
}

func New(st store.Store, cache *readcache.Cache, logger *slog.Logger, incr func(string, []string)) *Ranking {
	return &Ranking{store: st, readCache: cache, logger: logger, ddIncr: incr}
}
