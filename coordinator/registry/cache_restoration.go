package registry

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
)

type CacheRestorer interface{ Run(context.Context) error }

// CacheRestoration binds a restore attempt to its actual persistence generation.
// Both boot and retry use this operation before allowing persistence writes.
type CacheRestoration struct {
	registry  *Registry
	persister *cachepersist.Persister
	tracker   *cacheRoutingTracker
}

func (restore CacheRestoration) Run(ctx context.Context) error {
	r, persister, tracker := restore.registry, restore.persister, restore.tracker
	now := tracker.now()
	restoreCtx, cancel := context.WithTimeout(ctx, cacheRoutingRestoreTimeout)
	demand, err := persister.Restore(restoreCtx, now, tracker.settings.TTL, tracker.settings.MaxEntries, tracker.demand.limit)
	cancel()
	if err != nil {
		return err
	}
	persister.SeedDemandPersisted(tracker.demand.restore(demand, now))
	r.bindRestoredHoldersForConnectedProviders()
	return nil
}
