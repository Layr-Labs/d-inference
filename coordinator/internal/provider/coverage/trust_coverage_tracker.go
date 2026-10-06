package coverage

import (
	"log/slog"
	"sync"

	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// trustCoverageTracker advances only coordinator-observed hardware continuity.
// Coverage transitions share the same mutex regardless of which grant path or
// lifecycle event drives them.
type Tracker struct {
	registry        *registry.Registry
	logger          *slog.Logger
	trustReuseCache *trustreuse.Cache
	trustCoverageMu sync.Mutex
	trustCoverage   map[string]string
}

func New(reg *registry.Registry, logger *slog.Logger, cache *trustreuse.Cache) *Tracker {
	return &Tracker{
		registry: reg, logger: logger, trustReuseCache: cache,
		trustCoverage: make(map[string]string),
	}
}
