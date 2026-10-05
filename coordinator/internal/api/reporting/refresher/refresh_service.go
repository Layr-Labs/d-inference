package refresher

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
)

type Service struct {
	readCache *readcache.Cache
	logger    *slog.Logger
	ddIncr    func(string, []string)
}

func New(cache *readcache.Cache, logger *slog.Logger, incr func(string, []string)) *Service {
	return &Service{readCache: cache, logger: logger, ddIncr: incr}
}
