package registry

import "github.com/eigeninference/d-inference/coordinator/protocol"

type CacheSnapshotUpdating interface {
	Apply(string, bool, int, []protocol.PrefixCacheV2Capability, *[]protocol.PrefixCacheV2Capability, *[]protocol.PrefixCacheModelStatus, *[]protocol.PrefixCacheDonationOutcomeCount) (CacheSnapshotResult, error)
}

// CacheSnapshotUpdater publishes authoritative provider capabilities while
// retaining registry and provider ownership through evidence invalidation.
type CacheSnapshotUpdater struct{ registry *Registry }

// CacheParkedDrop identifies the durable bucket left behind by a publication.
type CacheParkedDrop struct{ Epoch, Model string }

// CacheSnapshotResult carries the bounded apply's deferred persistence work.
// Its operations reacquire and validate the original connection on each chunk.
type CacheSnapshotResult struct {
	Changed   bool
	Remaining bool
	Drops     []CacheParkedDrop
	registry  *Registry
	provider  *Provider
}

func (result CacheSnapshotResult) SettleDrop(drop CacheParkedDrop) {
	result.registry.dropParkedWhileStale(result.provider, parkedDrop{epoch: drop.Epoch, model: drop.Model})
}

func (result CacheSnapshotResult) BindRemaining() {
	if result.Remaining && result.provider != nil {
		result.registry.bindChunksWhileOwned(result.provider)
	}
}
