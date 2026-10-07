package registry_test

import (
	"encoding/base64"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/cachepersist"
	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Retain constructor inputs and the actual production owners, not Registry state.
type persistenceFixture struct {
	*production.Registry
	core           *cachetracker.Tracker[*production.Provider]
	config         cachetracker.Config[*production.Provider]
	demand         *cachedemand.Tracker
	query          production.CacheHintQuerier
	maintenance    production.CacheMaintainer
	restoration    production.CacheRestorer
	snapshots      production.CacheSnapshotUpdating
	persister      *cachepersist.Persister
	persistOptions cachepersist.Options
	routeKey       []byte
}

func newPersistenceFixture(t *testing.T, inputs ...production.CacheDependencies) (*persistenceFixture, *production.Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	f := &persistenceFixture{}
	var deps production.CacheDependencies
	if len(inputs) != 0 {
		deps = inputs[0]
	}
	deps.Trackers = func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
		f.config = config
		f.core = cachetracker.New(config)
		return f.core
	}
	deps.Demand = func(limit int, ttl time.Duration, history *cachehistory.Index) *cachedemand.Tracker {
		f.demand = cachedemand.New(limit, ttl, history)
		return f.demand
	}
	deps.HintQueries = func(query production.CacheHintQuery) production.CacheHintQuerier {
		f.query = query
		return query
	}
	deps.Maintenance = func(owner production.CacheMaintenance) production.CacheMaintainer {
		f.maintenance = owner
		return owner
	}
	deps.Persisters = func(st crs.Store, logger *slog.Logger, options cachepersist.Options) *cachepersist.Persister {
		f.persistOptions = options
		f.persister = cachepersist.New(st, logger, options)
		return f.persister
	}
	deps.Restorations = func(owner production.CacheRestoration) production.CacheRestorer {
		f.restoration = owner
		return owner
	}
	deps.Snapshots = func(owner production.CacheSnapshotUpdater) production.CacheSnapshotUpdating {
		f.snapshots = owner
		return owner
	}
	r, p, capability := exactTestRegistry(t, production.Dependencies{Cache: deps})
	f.Registry = r
	f.routeKey = cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3"))
	return f, p, capability
}

func persistenceBoundPlan(f *persistenceFixture, plan production.CachePlan) production.CachePlan {
	bound := preparationFixture{generation: f.config.Generation}
	return bound.bind(plan)
}

func persistenceHints(f *persistenceFixture, plan production.CachePlan, now time.Time) map[string]production.CacheRoutingHint {
	if !plan.HasOrigin() {
		plan = persistenceBoundPlan(f, plan)
	}
	hints, _ := f.query.Query("model", plan, f.routeKey, production.CacheRoutingOn, now)
	return hints
}

func persistenceAttempt(t *testing.T, f *persistenceFixture, p *production.Provider, capability protocol.PrefixCacheV2Capability, id string, plan production.CachePlan, sequence uint64) (*production.PendingRequest, *protocol.PrefixCacheReadyV2Message) {
	t.Helper()
	pr := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := f.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	metadata := pr.CacheAttemptSnapshot().MetadataMessage()
	if metadata.CacheReceiptNonce == "" || metadata.CacheReceiptBoundaryMode != capability.ReadyBoundaryMode {
		t.Fatalf("checkpoint attempt lost negotiated mode: %+v", pr)
	}
	prompt := plan.Boundaries[len(plan.Boundaries)-1]
	lookup := fenceTestV2Lookup(metadata.CacheReceiptNonce, capability, prompt, sequence)
	lookup.RequestID = id
	if !f.ApplyPrefixCacheLookupV2(p.ID, lookup) {
		t.Fatal("lookup rejected")
	}
	ready := fenceTestV2Ready(metadata.CacheReceiptNonce, capability, prompt, sequence+1)
	ready.RequestID = id
	return pr, ready
}

func persistenceFingerprint(t *testing.T, master []byte) string {
	t.Helper()
	f, _, _ := newPersistenceFixture(t)
	config := generationTestConfig(production.CacheRoutingOn)
	config.MasterKey = base64.RawURLEncoding.EncodeToString(master)
	if err := f.ConfigureCacheRouting(config); err != nil {
		t.Fatal(err)
	}
	startStoppedCachePersistence(t, f, memory.NewMemory(store.Config{}), false)
	return f.persistOptions.Fingerprint
}
