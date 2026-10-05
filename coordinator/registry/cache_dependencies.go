package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
	"log/slog"
	"time"
)

// CacheDependencies retains the receipt/evidence clock at construction. A
// configuration replacement keeps the same clock without mutating a live
// tracker. Demand observation, activation and TTFT use their wall clocks.
type CacheDependencies struct {
	Affinities        func(CacheAffinityEvaluation) CacheAffinityEvaluator
	SnapshotCommits   func(CacheSnapshotCommit) CacheSnapshotCommitting
	QuarantineCommits func(CacheQuarantineCommit) CacheQuarantiner
	Maintenance       func(CacheMaintenance) CacheMaintainer
	Restorations      func(CacheRestoration) CacheRestorer
	Snapshots         func(CacheSnapshotUpdater) CacheSnapshotUpdating
	Persisters        func(crs.Store, *slog.Logger, cachepersist.Options) *cachepersist.Persister
	Quarantines       func(CacheQuarantine) CacheQuarantiner
	HintQueries       func(CacheHintQuery) CacheHintQuerier
	// Positive limits override the default immutable receipt-index sizing.
	MaxEntries  int
	MaxAttempts int
	// Component factories retain the accepted config and actual index identities.
	Trackers          func(cachetracker.Config[*Provider]) *cachetracker.Tracker[*Provider]
	Holders           func() *cacheindex.Holders[cachetracker.Holder[*Provider]]
	DemandLimit       int
	Demand            func(int, time.Duration, *cachehistory.Index) *cachedemand.Tracker
	Now               func() time.Time
	Generations       func() *cacheplan.Generation
	Revisions         func(string) *cachepeer.Revision
	Publications      func(CachePublication) CachePublisher
	ReceiptAdmissions func(CacheReceiptAdmission) CacheReceiptAdmitter
	Nonces            func() (string, error)
	// Attempts constructs the actual receipt directory for each new generation.
	Attempts func() *cacheindex.Records[string, cachetracker.Attempt[*Provider]]
	// Fences constructs the actual quarantine directory for each new generation.
	Fences func() *cacheindex.Records[cachetracker.FenceKey, cachetracker.FenceRecord]
	Proofs func(*cacheplan.Generation, *cacheindex.Records[cachetracker.FenceKey, cachetracker.FenceRecord]) *cachetracker.Proofs
}

func (r *Registry) newCacheReceiptNonce() (string, error) {
	if r.cacheDependencies.Nonces != nil {
		return r.cacheDependencies.Nonces()
	}
	return newCacheReceiptNonce()
}

func (r *Registry) newCacheRevision(providerID string) *cachepeer.Revision {
	if r != nil && r.cacheDependencies.Revisions != nil {
		if revision := r.cacheDependencies.Revisions(providerID); revision != nil {
			return revision
		}
	}
	return cachepeer.NewRevision()
}

func (p *Provider) advanceCacheRevisionLocked() {
	if p.prefixCacheRevision == nil {
		p.prefixCacheRevision = cachepeer.NewRevision()
	}
	p.prefixCacheRevision.Advance()
}
