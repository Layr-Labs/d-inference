// Package cachepersist maintains a write-behind copy of the registry's exact
// SSD prefix-cache holder and demand indexes. Routing reads stay in memory;
// store IO runs outside registry locks. Restored holders park by cache epoch
// and model until a matching provider reconnects. Resident holders are never
// persisted.
package cachepersist

import (
	"log/slog"
	"time"

	core "github.com/eigeninference/d-inference/coordinator/internal/registry/cachepersist"
	cachequeue "github.com/eigeninference/d-inference/coordinator/internal/registry/cachequeue"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

type Persister = core.Persister
type Status = core.Status

const (
	FlushInterval            = 5 * time.Second
	PruneInterval            = 5 * time.Minute
	DemandPersistGranularity = cachequeue.DemandPersistGranularity
	DemandFlushRows          = cachequeue.DemandFlushRows
	HolderFlushRows          = cachequeue.HolderFlushRows
)

type Options struct {
	// MaxPending bounds parked holders. Each kind of pending write permits
	// four times that many entries; delete overflow resets the durable copy.
	MaxPending  int
	DemandTTL   time.Duration
	Fingerprint string
}

func New(st crs.Store, logger *slog.Logger, opts Options) *Persister {
	return core.New(st, logger, opts.Fingerprint, cachequeue.New(opts.MaxPending, opts.DemandTTL))
}

func ClampToTTL(rec crs.HolderRecord, now time.Time, ttl time.Duration) (crs.HolderRecord, bool) {
	return core.ClampToTTL(rec, now, ttl)
}
